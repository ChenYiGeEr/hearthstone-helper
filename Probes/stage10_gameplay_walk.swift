import Foundation
import AppKit
import Darwin

// 阶段十：对局核心类实例定位与字段映射
// 目标：Gameplay / ZoneMgr / Player 的 vtable → 实例 → 字段内容 → 找到 zones/entities/手牌
// 复用已实证配方：MonoClass(image@0x38,name@0x40) / MonoVTable(klass@0,domain@0x10) / 堆扫实例

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
func scanChunks(_ base: UInt64, _ size: UInt64, _ body: (UInt64, UnsafePointer<UInt64>, Int) -> Void) {
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(8 * 1024 * 1024, size - offset))
        guard let buf = read(base + offset, n) else { return }
        buf.withUnsafeBytes { raw in
            body(base + offset, raw.baseAddress!.assumingMemoryBound(to: UInt64.self), n / 8)
        }
        offset += UInt64(n)
    }
}

// ==== 一遍堆扫：全部目标类 + 对象→vtable 的引用图 ====
let targetNames = Set(["GameState", "Gameplay", "ZoneMgr", "Player", "Entity", "Zone", "EntityDef", "GameMgr", "Card"])
var classByName: [String: UInt64] = [:]
// 对象候选：[w]==某vtable；先收 vtable（[w]==类指针 && [w+0x10]==domain），一遍扫完 vtable 再一遍扫实例
var vtableByClass: [UInt64: UInt64] = [:]
var instancesByVtable: [UInt64: [UInt64]] = [:]

forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        for k in 0..<words {
            guard k + 2 < words else { break }
            let v = ptr[k]
            // vtable：[w]==类指针 && [w+0x10]==domain
            if ptr[k + 2] == domain, v > 0x10000, v < 0x8000_0000_0000, vtableByClass[v] == nil {
                vtableByClass[v] = chunkBase + UInt64(k * 8)
            }
        }
    }
    return true
}
print("✓ vtable 总数 \(vtableByClass.count)")

// 类地址→名字（对 vtable 的 klass 键验证名字）
var vtablesOfTargets: [String: UInt64] = [:]
for (klass, vt) in vtableByClass {
    guard classByName.values.contains(klass) || true else { continue }
}
// 反查：需要每个 klass 的名字——批量读取
for (klass, vt) in vtableByClass {
    guard let km = read(klass, 0x48) else { continue }
    guard u64(km, 0x38) == image else { continue }
    let np = u64(km, 0x40)
    guard isPtr(np), let s = cStr(np) else { continue }
    if targetNames.contains(s), vtablesOfTargets[s] == nil { vtablesOfTargets[s] = vt }
    if targetNames.contains(s), classByName[s] == nil { classByName[s] = klass }
}
print("✓ 目标类 vtable：")
for (n, vt) in vtablesOfTargets.sorted(by: { $0.key < $1.key }) {
    print("  \(n): vtable @ \(String(vt, radix: 16))")
}

// ==== 实例扫描（[obj]==vtable）====
let wanted = ["Gameplay", "ZoneMgr", "Player", "GameState"]
var instByClass: [String: [UInt64]] = [:]
let vtToName = Dictionary(uniqueKeysWithValues: vtablesOfTargets.map { ($0.value, $0.key) })
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        for k in 0..<words {
            guard let name = vtToName[ptr[k]] else { continue }
            let obj = chunkBase + UInt64(k * 8)
            if obj == ptr[k] { continue }
            instByClass[name, default: []].append(obj)
        }
    }
    return true
}
print("\n✓ 实例计数：")
for n in wanted {
    let list = instByClass[n] ?? []
    print("  \(n): \(list.count) 个")
}

// ==== dump Gameplay / ZoneMgr / Player 实例 ====
func dumpInstance(_ name: String, _ inst: UInt64, _ size: Int) {
    guard let om = read(inst, size) else { return }
    print("\n=== \(name) 实例 @ \(String(inst, radix: 16)) ===")
    for x in stride(from: 8, to: size, by: 8) {
        let y = u64(om, x)
        guard y != 0 else { continue }
        var d = String(y, radix: 16)
        if isPtr(y), y < 0x10000_0000 { d = "small:\(y)" }
        else if isPtr(y) {
            if let t = read(y, 0x10), isPtr(u64(t, 0)), let vt2 = read(u64(t, 0), 0x10) {
                let kl = u64(vt2, 0)
                if isPtr(kl), let km = read(kl, 0x48), u64(km, 0x38) == image, let n = cStr(u64(km, 0x40)) {
                    d = "→\(n)"
                }
            }
        } else {
            let lo = UInt32(truncatingIfNeeded: y), hi = UInt32(truncatingIfNeeded: y >> 32)
            d = "\(lo)|\(hi)"
        }
        print(String(format: "+%03X %@", x, d))
    }
}
if let inst = instByClass["Gameplay"]?.first { dumpInstance("Gameplay", inst, 0x200) }
if let inst = instByClass["ZoneMgr"]?.first { dumpInstance("ZoneMgr", inst, 0x200) }
if let inst = instByClass["Player"]?.first { dumpInstance("Player", inst, 0x180) }
print("\n完成")
