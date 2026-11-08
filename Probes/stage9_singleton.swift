import Foundation
import AppKit
import Darwin

// 阶段九：GameState 单例定位
// 已实证（stage8b + arm64 反汇编 + 实测）：
//   MonoClass: image@0x38, name@0x40, name_space@0x48, type_token@0x50(u32)
//   MonoVTable: klass@0x00, domain@0x10（Unity fork 无 MonoObject 头）
//   GameState vtable 可通过堆扫 [w]==类指针 && [w+0x10]==domain 找到
// 本阶段：类定位 → vtable 定位 → 堆扫实例 → dump 单例

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

// ==== 1. GameState MonoClass（堆扫签名 +0x38==image 且 name=="GameState"）====
var gsClass: UInt64 = 0
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        guard gsClass == 0 else { return }
        for k in 0..<words {
            guard k + 7 < words, ptr[k + 7] == image else { continue }
            let p = chunkBase + UInt64(k * 8)
            let np = ptr[k + 8]
            guard isPtr(np), let s = cStr(np), s == "GameState" else { continue }
            gsClass = p
        }
    }
    return gsClass == 0
}
guard gsClass != 0 else { print("GameState 类未找到"); exit(1) }
print("✓ GameState 类 @ \(String(gsClass, radix: 16))")

// ==== 2. GameState MonoVTable（堆扫 [w]==类指针 && [w+0x10]==domain）====
var gsVtable: UInt64 = 0
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        guard gsVtable == 0 else { return }
        for k in 0..<words {
            guard k + 2 < words, ptr[k] == gsClass, ptr[k + 2] == domain else { continue }
            gsVtable = chunkBase + UInt64(k * 8)
        }
    }
    return gsVtable == 0
}
guard gsVtable != 0 else { print("GameState vtable 未找到"); exit(1) }
print("✓ GameState vtable @ \(String(gsVtable, radix: 16))")

// ==== 3. 堆扫实例（[obj]==vtable 指针）====
var instances: [UInt64] = []
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        for k in 0..<words where ptr[k] == gsVtable {
            let obj = chunkBase + UInt64(k * 8)
            if obj != gsVtable { instances.append(obj) }
        }
    }
    return true
}
print("✓ GameState 实例 \(instances.count) 个")
for (i, o) in instances.prefix(5).enumerated() {
    print("  [\(i)] \(String(o, radix: 16))")
}

// ==== 4. dump 首个实例 ====
if let inst = instances.first {
    guard let om = read(inst, 0x200) else { exit(1) }
    print("\n=== GameState 实例 dump（0x200）===")
    for x in stride(from: 0, to: 0x200, by: 8) {
        let y = u64(om, x)
        guard y != 0 else { continue }
        var d = String(y, radix: 16)
        if y == gsVtable { d = "vtable!" }
        else if y == domain { d = "domain!" }
        else if isPtr(y) {
            // 指向其他对象 → 报告目标类名
            if let t = read(y, 0x10), let vtPtr = read(u64(t, 0), 0x10), isPtr(u64(t, 0)) {
                let kl = u64(vtPtr, 0)
                if isPtr(kl), let km = read(kl, 0x48) {
                    if u64(km, 0x38) == image, let n = cStr(u64(km, 0x40)) {
                        d = "→\(n)对象"
                    }
                }
            }
        }
        print(String(format: "+%03X %@", x, d))
    }
}
print("\n完成")
