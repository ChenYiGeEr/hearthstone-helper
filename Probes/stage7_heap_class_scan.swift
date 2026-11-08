import Foundation
import AppKit
import Darwin

// 阶段七：GC 堆扫描定位 GameState 等 MonoClass
// MonoClass 签名（stage6 实证）：+0x38 = Assembly-CSharp image，+0x40 = 名字 char*
// 方法：mach_vm_region_recurse 枚举远程可读区域，本地扫描 [p+0x38]==image 的候选，再远程验证名字

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { print("炉石未运行"); exit(1) }
var task: mach_port_t = 0
let hmHandle = dlopen("HearthMirror.framework/HearthMirror", RTLD_NOW) ?? dlopen(nil, RTLD_NOW)
if let hmHandle, let sym = dlsym(hmHandle, "acquireTaskportRight") {
    _ = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)()
}
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else {
    print("task_for_pid 失败"); exit(1)
}
func read(_ addr: UInt64, _ size: Int) -> Data? {
    var p: vm_offset_t = 0; var c: mach_msg_type_number_t = 0
    guard vm_read(task, vm_address_t(addr), vm_size_t(size), &p, &c) == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, p, vm_size_t(c)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: p)!, count: Int(c))
}
func cStr(_ addr: UInt64, max: Int = 64) -> String? {
    guard let d = read(addr, max) else { return nil }
    let b = d.prefix { $0 != 0 }
    guard !b.isEmpty, b.count <= 60 else { return nil }
    return String(bytes: b, encoding: .utf8)
}
func isPtr(_ p: UInt64) -> Bool { p > 0x10000 && p < 0x8000_0000_0000 }

var info = task_dyld_info_data_t()
var dcnt = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / 4)
_ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(dcnt)) { task_info(task, 17, $0, &dcnt) } }
guard let h = read(info.all_image_info_addr, 16) else { exit(1) }
let ic = Int(h.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let ia = h.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
guard let arr = read(ia, ic * 24) else { exit(1) }
var mono: UInt64?
for i in 0..<ic {
    let la = arr.withUnsafeBytes { $0.load(fromByteOffset: i*24, as: UInt64.self) }
    let fp = arr.withUnsafeBytes { $0.load(fromByteOffset: i*24+8, as: UInt64.self) }
    guard let pd = read(fp, 512) else { continue }
    if (String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? "").contains("libmonobdwgc") { mono = la; break }
}
guard let mono else { print("no mono"); exit(1) }
let exp = mono + 0x11853c
guard let ins = read(exp, 8) else { exit(1) }
let i1 = ins.withUnsafeBytes { $0.load(as: UInt32.self) }, i2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
var imm = Int((((i1 >> 5) & 0x7FFFF) << 2) | ((i1 >> 29) & 0x3))
if imm & (1 << 20) != 0 { imm -= (1 << 21) }
let domain = read((exp & ~0xFFF) + UInt64(imm * 4096) + UInt64(((i2 >> 10) & 0xFFF) * 8), 8)!.withUnsafeBytes { $0.load(as: UInt64.self) }
guard let dm = read(domain, 0x2000) else { exit(1) }
var node = dm.withUnsafeBytes { $0.load(fromByteOffset: 0xB0, as: UInt64.self) }
var image: UInt64?
for _ in 0..<200 {
    guard let d = read(node, 16) else { break }
    let data = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let next = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    guard let am = read(data, 0x100) else { break }
    for off in stride(from: 0, to: 0x100, by: 8) {
        let img = am.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
        guard let im = read(img, 0x100) else { continue }
        for io in stride(from: 0, to: 0x100, by: 8) {
            let np = im.withUnsafeBytes { $0.load(fromByteOffset: io, as: UInt64.self) }
            let s = read(np, 64).map { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? "" } ?? ""
            if s == "Assembly-CSharp.dll" { image = img; break }
        }
        if image != nil { break }
    }
    if image != nil { break }
    if next == 0 { break }
    node = next
}
guard let image else { print("no Assembly-CSharp"); exit(1) }
print("✓ image @ \(String(image, radix: 16))")

// ==== VM 区域枚举 + 堆扫描 ====
let targets = Set(["GameState", "Gameplay", "Player", "Zone", "EntityDef", "GameMgr", "ZoneMgr", "Entity", "Card", "TurnTimer", "MulliganManager", "PowerProcessor", "NetworkHistory"])
var found: [String: UInt64] = [:]
var classCount = 0
var scannedMB = 0

var address: UInt64 = 0x1000
var nesting = 0
while true {
    var size: mach_vm_size_t = 0
    var infoAddr = mach_vm_address_t(address)
    var basic = vm_region_basic_info_data_64_t()
    var infoCnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = 0
    let kr = withUnsafeMutablePointer(to: &basic) { ptr in
        mach_vm_region(task, &infoAddr, &size,
            vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
            UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCnt, &objectName)
    }
    guard kr == KERN_SUCCESS else { break }
    defer { address = UInt64(infoAddr) + size }
    let prot = basic.protection
    guard prot & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }

    // 分块读入并本地扫描
    let chunkSize = 8 * 1024 * 1024
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(UInt64(chunkSize), size - offset))
        guard let buf = read(UInt64(infoAddr) + offset, n) else { break }
        scannedMB += n / (1024 * 1024)
        let words = n / 8
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            for k in 0..<words {
                // p+0x38 的 image 检查在缓冲区内完成
                guard k + 7 < words else { break }
                guard base[k + 7] == image else { continue }
                let p = UInt64(infoAddr) + offset + UInt64(k * 8)
                // 候选 MonoClass：进一步验证 name
                let npRaw = base[k + 8]
                guard isPtr(npRaw) else { continue }
                guard let s = cStr(npRaw) else { continue }
                guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" || $0 == "." }) else { continue }
                classCount += 1
                if targets.contains(s), found[s] == nil { found[s] = p }
            }
        }
        offset += UInt64(n)
    }
    if scannedMB % 512 < 8 { print("  已扫 \(scannedMB)MB，类 \(classCount)，目标命中 \(found.count)") }
    if found.count == targets.count { break }
}
print("✓ 扫描完成：\(scannedMB)MB，MonoClass \(classCount) 个")
print("\n=== 目标类 ===")
for (n, a) in found.sorted(by: { $0.key < $1.key }) {
    print("  \(n) @ \(String(a, radix: 16))")
}
