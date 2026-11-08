import Foundation
import AppKit
import Darwin

// 阶段二 c：MonoImage 的 class_cache 发现 + MonoClass name 偏移锚定
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { print("炉石未运行"); exit(1) }

var task: mach_port_t = 0
let handle = dlopen("HearthMirror.framework/HearthMirror", RTLD_NOW) ?? dlopen(nil, RTLD_NOW)
if let handle, let sym = dlsym(handle, "acquireTaskportRight") {
    let fn = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    _ = fn()
}
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else {
    print("task_for_pid 失败"); exit(1)
}
func read(_ addr: UInt64, _ size: Int) -> Data? {
    var dataPtr: vm_offset_t = 0
    var dataCount: mach_msg_type_number_t = 0
    let kr = vm_read(task, vm_address_t(addr), vm_size_t(size), &dataPtr, &dataCount)
    guard kr == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, dataPtr, vm_size_t(dataCount)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: dataPtr)!, count: Int(dataCount))
}
func cString(at addr: UInt64, max: Int = 128) -> String? {
    guard let d = read(addr, max) else { return nil }
    let bytes = d.prefix { $0 != 0 }
    guard bytes.count >= 3 else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}
func isPlausiblePtr(_ p: UInt64) -> Bool { p > 0x1000_0000 && p < 0x8000_0000_0000 }

// —— 前段（阶段一/二已验证）：定位 mono → 根域 → Assembly-CSharp image ——
var info = task_dyld_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size)
_ = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(17), $0, &count)
    }
}
let dyldAddr = info.all_image_info_addr
guard let header = read(dyldAddr, 16) else { exit(1) }
let imageCount = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let infoArray = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
guard let arrayData = read(infoArray, imageCount * 24) else { exit(1) }
var monoLoadAddr: UInt64?
for i in 0..<imageCount {
    let off = i * 24
    let loadAddr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    let fp = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt64.self) }
    guard let pd = read(fp, 512) else { continue }
    if (String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? "").contains("libmonobdwgc") { monoLoadAddr = loadAddr; break }
}
guard let loadAddr = monoLoadAddr else { exit(1) }
let exportAddr = loadAddr + 0x11853c
guard let ins = read(exportAddr, 8) else { exit(1) }
let i1 = ins.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
let i2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
let immlo = (i1 >> 29) & 0x3
let immhi = (i1 >> 5) & 0x7FFFF
var imm = Int((immhi << 2) | immlo)
if imm & (1 << 20) != 0 { imm -= (1 << 21) }
let domain = read((exportAddr & ~UInt64(0xFFF)) + UInt64(imm * 4096) + UInt64(((i2 >> 10) & 0xFFF) * 8), 8)!
    .withUnsafeBytes { $0.load(as: UInt64.self) }
guard let domainMem = read(domain, 0x2000) else { exit(1) }
var assemblyChain: [UInt64] = []
// 从 +0xB0 走 GSList
var chainHead = domainMem.withUnsafeBytes { $0.load(fromByteOffset: 0xB0, as: UInt64.self) }
var node = chainHead
for _ in 0..<200 {
    guard isPlausiblePtr(node), let d = read(node, 16) else { break }
    let data = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let next = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    guard isPlausiblePtr(data) else { break }
    assemblyChain.append(data)
    if next == 0 { break }
    node = next
}
// 找 Assembly-CSharp 的 image
var csharpImage: UInt64?
for assembly in assemblyChain {
    guard let amem = read(assembly, 0x100) else { continue }
    for off in stride(from: 0, to: 0x100, by: 8) {
        let image = amem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
        guard isPlausiblePtr(image), let imem = read(image, 0x200) else { continue }
        for ioff in stride(from: 0, to: 0x200, by: 8) {
            let np = imem.withUnsafeBytes { $0.load(fromByteOffset: ioff, as: UInt64.self) }
            guard isPlausiblePtr(np), let s = cString(at: np, max: 64), s == "Assembly-CSharp.dll" else { continue }
            csharpImage = image
            break
        }
        if csharpImage != nil { break }
    }
    if csharpImage != nil { break }
}
guard let image = csharpImage else { print("未找到 Assembly-CSharp image"); exit(1) }
print("✓ Assembly-CSharp MonoImage @ \(String(image, radix: 16))")
guard let imageMem = read(image, 0xC00) else { exit(1) }
let monoTextLo = loadAddr
let monoTextHi = loadAddr + 0x320000

// ===== 诊断：全部指针字段摘要 =====
print("=== MonoImage 指针字段摘要 ===")
for off in stride(from: 0x00, to: 0xC00, by: 8) {
    let p = imageMem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPlausiblePtr(p) else { continue }
    let inMono = p >= monoTextLo && p < monoTextHi
    var desc = inMono ? "mono代码段" : ""
    if !inMono, let d = read(p, 32) {
        let f1 = d.withUnsafeBytes { $0.load(as: UInt64.self) }
        let f2 = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        desc = "→[\(String(f1, radix: 16)), \(String(f2, radix: 16))]"
        if f1 >= monoTextLo && f1 < monoTextHi { desc += " f1=mono代码段!" }
        if let s = cString(at: p, max: 32) { desc += " str=\(s.prefix(20))" }
    }
    print(String(format: "+0x%03X %@", off, desc.isEmpty ? String(p, radix: 16) : desc))
}
print("扫描完成")
