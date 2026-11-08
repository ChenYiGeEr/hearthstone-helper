import Foundation
import AppKit
import Darwin

// 阶段五 b：MonoImage 后段（0x440~0x740）原始结构 dump + 指针一层追踪
// 目的：找到 class_cache（MonoClass 名字哈希表）的真实布局

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
func cStr(_ addr: UInt64, max: Int = 48) -> String? {
    guard let d = read(addr, max) else { return nil }
    let b = d.prefix { $0 != 0 }
    guard !b.isEmpty, b.count <= 40 else { return nil }
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
print("✓ image @ \(String(image, radix: 16))  mono @ \(String(mono, radix: 16))")
let monoTextHi = mono + 0x320000

guard let imem = read(image, 0xC00) else { exit(1) }
print("\n=== 原始 dump 0x440~0x740（每行 4 个 u64）===")
for off in stride(from: 0x440, to: 0x740, by: 32) {
    var line = String(format: "+0x%03X", off)
    for k in 0..<4 {
        let v = imem.withUnsafeBytes { $0.load(fromByteOffset: off + k * 8, as: UInt64.self) }
        line += String(format: " %016llx", v)
    }
    print(line)
}

print("\n=== 指针一层追踪 ===")
for off in stride(from: 0x440, to: 0x740, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPtr(p), !(p >= mono && p < monoTextHi) else { continue }
    guard let d = read(p, 64) else { continue }
    var words: [String] = []
    for k in 0..<8 {
        let v = d.withUnsafeBytes { $0.load(fromByteOffset: k * 8, as: UInt64.self) }
        if v == 0 { words.append("0") }
        else if v >= mono && v < monoTextHi { words.append("mono") }
        else if isPtr(v) {
            if let s = cStr(v, max: 32) { words.append("'\(s.prefix(12))'") }
            else { words.append(String(v, radix: 16)) }
        } else {
            // 小整数可读为 u32 对
            let lo = UInt32(truncatingIfNeeded: v), hi = UInt32(truncatingIfNeeded: v >> 32)
            words.append("\(lo)|\(hi)")
        }
    }
    print(String(format: "+0x%03X → %@", off, String(p, radix: 16)) + ": [" + words.joined(separator: " ") + "]")
}

print("\n=== 哈希表候选深挖（目标 = {mono代码指针, mono代码指针}）===")
for off in stride(from: 0x440, to: 0x740, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPtr(p), !(p >= mono && p < monoTextHi) else { continue }
    guard let d = read(p, 48) else { continue }
    let f1 = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let f2 = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    guard f1 >= mono, f1 < monoTextHi, f2 >= mono, f2 < monoTextHi else { continue }
    // MonoInternalHashTable 期望: +16 桶数组, +24 桶数(2的幂), +28 条目数——也可能布局再移位
    var vals: [String] = []
    for k in 2..<6 {
        let v = d.withUnsafeBytes { $0.load(fromByteOffset: k * 8, as: UInt64.self) }
        let lo = UInt32(truncatingIfNeeded: v), hi = UInt32(truncatingIfNeeded: v >> 32)
        if isPtr(v) { vals.append("p:" + String(v, radix: 16)) }
        else { vals.append("\(lo)|\(hi)") }
    }
    print(String(format: "image+0x%03X → %@", off, String(p, radix: 16)) + " +16..40 = " + vals.joined(separator: "  "))
}
