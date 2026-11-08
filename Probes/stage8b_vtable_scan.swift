import Foundation
import AppKit
import Darwin

// 阶段八 b：两遍堆扫描 → MonoVTable → GameState 静态存储
// 第一遍：收集 Assembly-CSharp 全部 MonoClass 地址（签名 +0x38==image）
// 第二遍：找 [w+0x10]∈类集合 && [w+0x18]==domain 的 MonoVTable，定位 GameState 的
// 第三遍：vtable 的 data 指针区找 GameState 实例（[obj]→vt, [vt+0x10]==GameState类）

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
func u64(_ d: Data, _ o: Int) -> UInt64 { d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) } }

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
print("✓ image @ \(String(image, radix: 16))  domain @ \(String(domain, radix: 16))")

// ==== 堆区域枚举器 ====
func forEachRegion(_ body: (UInt64, UInt64) -> Bool) {
    var address: UInt64 = 0x1000
    while true {
        var size: mach_vm_size_t = 0
        var infoAddr = mach_vm_address_t(address)
        var basic = vm_region_basic_info_data_64_t()
        var infoCnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
        var objectName: mach_port_t = 0
        let kr = withUnsafeMutablePointer(to: &basic) { ptr in
            mach_vm_region(task, &infoAddr, &size, vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
                UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCnt, &objectName)
        }
        guard kr == KERN_SUCCESS else { return }
        defer { address = UInt64(infoAddr) + size }
        guard basic.protection & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }
        if !body(UInt64(infoAddr), size) { return }
    }
}
func scanChunks(_ base: UInt64, _ size: UInt64, _ body: (UnsafePointer<UInt64>, Int) -> Void) {
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(8 * 1024 * 1024, size - offset))
        guard let buf = read(base + offset, n) else { return }
        buf.withUnsafeBytes { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: UInt64.self), n / 8)
        }
        offset += UInt64(n)
    }
}

// ==== 第一遍：类集合 ====
var classAddrs = Set<UInt64>()
forEachRegion { base, size in
    scanChunks(base, size) { ptr, words in
        for k in 0..<words {
            guard k + 7 < words, ptr[k + 7] == image else { continue }
            classAddrs.insert(UInt64(base) + UInt64(k * 8))
        }
    }
    return true
}
print("✓ 第一遍：MonoClass \(classAddrs.count) 个")

// ==== 第二遍：MonoVTable（+0x10 ∈ 类集合，+0x18 == domain）====
var vtCandidates: [UInt64] = []
forEachRegion { base, size in
    scanChunks(base, size) { ptr, words in
        for k in 0..<words {
            guard k + 3 < words, ptr[k + 3] == domain else { continue }
            let kl = ptr[k + 2]
            guard kl > 0x10000, kl < 0x8000_0000_0000, classAddrs.contains(kl) else { continue }
            let w = UInt64(base) + UInt64(k * 8)
            if ptr[k] > 0x10000, ptr[k] < 0x8000_0000_0000 { vtCandidates.append(w) }
        }
    }
    return true
}
print("✓ 第二遍：MonoVTable 候选 \(vtCandidates.count) 个")

// GameState 的 vtable
let gameStateClass = vtCandidates.first.flatMap { _ in classAddrs.first { _ in false } } // 占位
var gsClass: UInt64 = 0
// 需要类地址→名字：对类集合抽查 GameState
for c in classAddrs {
    guard let cm = read(c, 0x48) else { continue }
    let np = u64(cm, 0x40)
    guard isPtr(np), let s = cStr(np), s == "GameState" else { continue }
    gsClass = c
    break
}
guard gsClass != 0 else { print("GameState 类未在集合中"); exit(1) }
print("✓ GameState 类 @ \(String(gsClass, radix: 16))")

var gsVtable: UInt64 = 0
for w in vtCandidates {
    guard let vm = read(w, 0x20) else { continue }
    if u64(vm, 0x10) == gsClass { gsVtable = w; break }
}
guard gsVtable != 0 else {
    print("未找到 GameState vtable（候选 \(vtCandidates.count) 个，布局需再核）")
    if let first = vtCandidates.first, let vm = read(first, 0x40) {
        print("首个 vtable 候选 dump \(String(first, radix: 16)):")
        for x in stride(from: 0, to: 0x40, by: 8) {
            let y = u64(vm, x)
            guard y != 0 else { continue }
            print(String(format: "  +%02X %@", x, y == domain ? "domain!" : String(y, radix: 16)))
        }
    }
    exit(1)
}
print("✓ GameState vtable @ \(String(gsVtable, radix: 16))")

// ==== dump vtable + 静态存储找实例 ====
guard let vm = read(gsVtable, 0x80) else { exit(1) }
print("=== GameState MonoVTable ===")
for x in stride(from: 0, to: 0x80, by: 8) {
    let y = u64(vm, x)
    guard y != 0 else { continue }
    var d = String(y, radix: 16)
    if y == gsClass { d = "GameState类!!" } else if y == domain { d = "domain!" }
    print(String(format: "+%02X %@", x, d))
}
print("\n=== 静态存储探测（vtable 内堆指针区各扫 0x400）===")
for x in stride(from: 0x20, to: 0x80, by: 8) {
    let q = u64(vm, x)
    guard isPtr(q), q != gsClass, !(q >= mono && q < mono + 0x320000) else { continue }
    guard let qm = read(q, 0x400) else { continue }
    var found: [String] = []
    for o in stride(from: 0, to: 0x400, by: 8) {
        let obj = u64(qm, o)
        guard isPtr(obj) else { continue }
        guard let om = read(obj, 0x18) else { continue }
        let vt = u64(om, 0)
        guard isPtr(vt), let vm2 = read(vt, 0x18) else { continue }
        if u64(vm2, 0x10) == gsClass {
            found.append(" GameState实例 @ \(String(obj, radix: 16))")
        }
    }
    if !found.isEmpty { print("data候选 +0x\(String(x, radix: 16)) →\(String(q, radix: 16)):\(found.joined())") }
}
print("完成")
