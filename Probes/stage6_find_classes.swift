import Foundation
import AppKit
import Darwin

// 阶段六：精确定位 GameState/Player/Zone 的 MonoClass
// 已实证 MonoClass 布局（mono 版本 = libmonobdwgc-2.0, T5）：
//   +0x38 image, +0x40 name(char*), +0x48 name_space(char*, 可指向 #Strings), +0x50 type_token(u32)
// 方法：遍历 MonoImage 全部哈希表桶数组，按布局签名收集 MonoClass，名字匹配目标类

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

let monoHi = mono + 0x320000

// 收集 image 里全部哈希表候选（目标 = {mono代码指针, mono代码指针, 桶数组,...}）
guard let imem = read(image, 0xC00) else { exit(1) }
var tables: [(off: Int, buckets: UInt64)] = []
for off in stride(from: 0x80, to: 0xC00, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPtr(p), !(p >= mono && p < monoHi) else { continue }
    guard let d = read(p, 24) else { continue }
    let f1 = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let f2 = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    guard f1 >= mono, f1 < monoHi, f2 >= mono, f2 < monoHi else { continue }
    let bkt = d.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
    guard isPtr(bkt) else { continue }
    tables.append((off, bkt))
}
print("✓ 哈希表候选 \(tables.count) 个")

// 逐表扫描桶区域，MonoClass 签名：[p+0x38]==image 且 [p+0x40] 名字可读
let targets = Set(["GameState", "Gameplay", "Player", "Zone", "EntityDef", "GameMgr", "ZoneMgr", "Card", "Entity"])
var found: [String: UInt64] = [:]
var totalClasses = 0

// 种子收集 + BFS 链遍历（MonoClass 之间的 next_class_cache 等互链会自然被跟随）
var seeds = Set<UInt64>()
for t in tables {
    guard let scan = read(t.buckets, 256 * 1024) else { continue }
    for o in stride(from: 0, to: scan.count - 8, by: 8) {
        let p = scan.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) }
        guard isPtr(p) else { continue }
        guard let cm = read(p, 0x58) else { continue }
        guard cm.withUnsafeBytes { $0.load(fromByteOffset: 0x38, as: UInt64.self) } == image else { continue }
        let np = cm.withUnsafeBytes { $0.load(fromByteOffset: 0x40, as: UInt64.self) }
        guard isPtr(np), cStr(np) != nil else { continue }
        seeds.insert(p)
    }
}
print("✓ 种子 \(seeds.count) 个，开始 BFS")

var visited = Set<UInt64>()
var frontier = Array(seeds)
var all: [(addr: UInt64, name: String)] = []
while !frontier.isEmpty {
    let p = frontier.removeLast()
    guard !visited.contains(p), visited.count < 30000 else { continue }
    visited.insert(p)
    guard let cm = read(p, 0x100) else { continue }
    let np = cm.withUnsafeBytes { $0.load(fromByteOffset: 0x40, as: UInt64.self) }
    guard isPtr(np), let s = cStr(np) else { continue }
    all.append((p, s))
    if targets.contains(s), found[s] == nil { found[s] = p }
    // 跟随所有指向同类对象的指针
    for w in stride(from: 0, to: 0x100, by: 8) {
        let v = cm.withUnsafeBytes { $0.load(fromByteOffset: w, as: UInt64.self) }
        guard isPtr(v), !visited.contains(v), v != image else { continue }
        guard let vm = read(v, 0x58) else { continue }
        guard vm.withUnsafeBytes { $0.load(fromByteOffset: 0x38, as: UInt64.self) } == image else { continue }
        let vn = vm.withUnsafeBytes { $0.load(fromByteOffset: 0x40, as: UInt64.self) }
        guard isPtr(vn), cStr(vn) != nil else { continue }
        frontier.append(v)
    }
    if visited.count % 2000 == 0 { print("  BFS 进度 \(visited.count)") }
}
print("✓ BFS 完成：\(visited.count) 个 MonoClass")
print("\n=== 目标类 ===")
for (n, a) in found.sorted(by: { $0.key < $1.key }) {
    print("  \(n) @ \(String(a, radix: 16))")
}

// GameState 结构速览：字段/方法/属性数组指针区
if let gs = found["GameState"] {
    guard let gmem = read(gs, 0x100) else { exit(1) }
    print("\n=== GameState MonoClass +0x50~0xF8 ===")
    for w in stride(from: 0x50, to: 0x100, by: 8) {
        let v = gmem.withUnsafeBytes { $0.load(fromByteOffset: w, as: UInt64.self) }
        guard v != 0 else { continue }
        var d = String(v, radix: 16)
        if isPtr(v) {
            if let s = cStr(v) { d = "→'\(s)'" }
            let tok = read(v, 8).map { $0.withUnsafeBytes { $0.load(as: UInt32.self) } }
            if let tk = tok, (tk >> 24) == 0x02 { d += " (TypeDef token 0x\(String(tk, radix: 16)))" }
            if let tk = tok, (tk >> 24) == 0x04 { d += " (Field token 0x\(String(tk, radix: 16)))" }
            if let tk = tok, (tk >> 24) == 0x06 { d += " (MethodDef token 0x\(String(tk, radix: 16)))" }
        }
        print(String(format: "+%03X %@", w, d))
    }
}
