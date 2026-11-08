import Foundation
import AppKit
import Darwin

// 阶段五 c：宽容扫描哈希表桶数组 → 用名字反查 GameState/Player/Zone 的 MonoClass
// 不依赖 MonoInternalHashTable 精确布局：候选 +16 处取桶数组指针，扫描其中回指本 image 的 MonoClass

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

// 哈希表候选（stage5b 实测：目标以双 mono 代码指针开头）
guard let imem = read(image, 0xC00) else { exit(1) }
var tableTargets: [(off: Int, buckets: UInt64)] = []
for off in stride(from: 0x440, to: 0x740, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPtr(p), !(p >= mono && p < mono + 0x320000) else { continue }
    guard let d = read(p, 24) else { continue }
    let f1 = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let f2 = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    guard f1 >= mono, f1 < mono + 0x320000, f2 >= mono, f2 < mono + 0x320000 else { continue }
    let bkt = d.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
    guard isPtr(bkt) else { continue }
    tableTargets.append((off, bkt))
}
print("✓ 哈希表候选 \(tableTargets.count) 个")

// 对每个候选桶数组：扫描 96KB，收集 [p+0x10]==image 的 MonoClass，各 name 偏移试名字
let nameOffsets = [0x18, 0x20, 0x28]
let targets = ["GameState", "Gameplay", "Player", "Zone", "EntityDef", "GameMgr"]

for t in tableTargets {
    guard let scan = read(t.buckets, 96 * 1024) else { continue }
    var found: [String: UInt64] = [:]
    var classCount = 0
    var seen = Set<UInt64>()
    var hitCount = [Int: Int](uniqueKeysWithValues: nameOffsets.map { ($0, 0) })
    for o in stride(from: 0, to: scan.count - 8, by: 8) {
        let p = scan.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) }
        guard isPtr(p), !seen.contains(p) else { continue }
        guard let cm = read(p, 0x40) else { continue }
        // MonoClass 布局版本不确定：image 在 +0x10（mono2.0 老布局）或 +0x20（mono6.x class_kind 开头）
        let imgOld = cm.withUnsafeBytes { $0.load(fromByteOffset: 0x10, as: UInt64.self) }
        let imgNew = cm.withUnsafeBytes { $0.load(fromByteOffset: 0x20, as: UInt64.self) }
        let imgOff = imgOld == image ? 0x10 : (imgNew == image ? 0x20 : -1)
        guard imgOff > 0 else { continue }
        seen.insert(p)
        classCount += 1
        for no in nameOffsets {
            let np = cm.withUnsafeBytes { $0.load(fromByteOffset: no, as: UInt64.self) }
            guard isPtr(np), let s = cStr(np) else { continue }
            if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" }) {
                hitCount[no, default: 0] += 1
            }
            if targets.contains(s), found[s] == nil { found[s] = p }
        }
    }
    if classCount > 20 {
        let hits = found.map { $0.key }.sorted().joined(separator: ",")
        print("image+0x\(String(t.off, radix: 16)) 桶@\(String(t.buckets, radix: 16)): 候选类 \(classCount)，name命中 \(hitCount.map { "+0x\(String($0.key, radix: 16)):\($0.value)" }.joined(separator: " ")) → 目标: \(hits)")
        if let gs = found["GameState"] {
            print("\n★ GameState MonoClass @ \(String(gs, radix: 16))")
        }
    }
}
