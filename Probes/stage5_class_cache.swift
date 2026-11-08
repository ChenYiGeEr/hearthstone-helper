import Foundation
import AppKit
import Darwin

// 阶段五：MonoImage class_cache 哈希表遍历 → 定位 GameState/Player/Zone 的 MonoClass
// 前置：阶段一~四已验证的附着/定位/BSJB 链路

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
func cStr(_ addr: UInt64, max: Int = 96) -> String? {
    guard let d = read(addr, max) else { return nil }
    let b = d.prefix { $0 != 0 }
    guard !b.isEmpty, b.count <= 90 else { return nil }
    return String(bytes: b, encoding: .utf8)
}
func isPtr(_ p: UInt64) -> Bool { p > 0x10000 && p < 0x8000_0000_0000 }

// ==== 附着 → 根域 → Assembly-CSharp image（复用已验证链路）====
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
print("✓ Assembly-CSharp image @ \(String(image, radix: 16))")

let monoTextLo = mono
let monoTextHi = mono + 0x320000

// ==== 扫描 MonoImage 里的 MonoInternalHashTable（class_cache 候选）====
// 签名：+0/+8 指向 mono 代码段，+24 桶数组指针，+32 桶数（2 的幂），+36 条目数
guard let imem = read(image, 0xC00) else { exit(1) }
var candidates: [(off: Int, buckets: UInt64, size: Int, entries: Int)] = []
for off in stride(from: 0x300, to: 0xC00, by: 8) {
    func w(_ o: Int) -> UInt64 { imem.withUnsafeBytes { $0.load(fromByteOffset: off + o, as: UInt64.self) } }
    let f1 = w(0), f2 = w(8)
    guard f1 >= monoTextLo, f1 < monoTextHi, f2 >= monoTextLo, f2 < monoTextHi else { continue }
    let bkt = w(24)
    let szU = w(32), entU = w(36)
    guard isPtr(bkt), szU >= 16, szU <= 65536, szU & (szU - 1) == 0, entU <= 20000 else { continue }
    let size = Int(szU), entries = Int(entU)
    candidates.append((off, bkt, size, entries))
}
print("✓ 哈希表候选 \(candidates.count) 个：")
for c in candidates {
    print(String(format: "  +0x%03X size=%d entries=%d", c.off, c.size, c.entries))
}

// ==== 遍历桶数组，收集 MonoClass*，探测 name 指针偏移 ====
// MonoClass 布局未知 → 对候选 name 偏移 0x18/0x20/0x28 统计命中率
let nameOffsets = [0x18, 0x20, 0x28]
var nameHits = [Int: Int](uniqueKeysWithValues: nameOffsets.map { ($0, 0) })
var allClasses: [(addr: UInt64, mem: Data)] = []
var seen = Set<UInt64>()

for c in candidates {
    guard let bkt = read(c.buckets, c.size * 8) else { continue }
    for b in 0..<c.size {
        let cls = bkt.withUnsafeBytes { $0.load(fromByteOffset: b * 8, as: UInt64.self) }
        guard isPtr(cls), !seen.contains(cls) else { continue }
        // 桶头不一定是链首类——校验它至少像 MonoClass：image 指针应指向本 image
        guard let mem = read(cls, 0x40) else { continue }
        let img = mem.withUnsafeBytes { $0.load(fromByteOffset: 0x10, as: UInt64.self) }
        guard img == image else { continue }
        seen.insert(cls)
        allClasses.append((cls, mem))
        for no in nameOffsets {
            let np = mem.withUnsafeBytes { $0.load(fromByteOffset: no, as: UInt64.self) }
            guard isPtr(np), let s = cStr(np, max: 64), !s.isEmpty,
                  s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" }) else { continue }
            nameHits[no, default: 0] += 1
        }
    }
}
print("\n=== name 偏移命中率（\(allClasses.count) 个桶头类）===")
for no in nameOffsets { print("  +0x\(String(no, radix: 16)) → \(nameHits[no] ?? 0)") }

// 用命中率最高的偏移找目标类
let bestOff = nameOffsets.max { (nameHits[$0] ?? 0) < (nameHits[$1] ?? 0) } ?? 0x18
print("★ name 偏移 = +0x\(String(bestOff, radix: 16))")

var found: [String: UInt64] = [:]
for (addr, mem) in allClasses {
    let np = mem.withUnsafeBytes { $0.load(fromByteOffset: bestOff, as: UInt64.self) }
    guard isPtr(np), let s = cStr(np, max: 64) else { continue }
    if ["GameState", "Gameplay", "Player", "Zone", "EntityDef", "GameMgr"].contains(s), found[s] == nil {
        found[s] = addr
    }
}
print("\n=== 目标类定位 ===")
for (n, a) in found.sorted(by: { $0.key < $1.key }) {
    print("  \(n) @ \(String(a, radix: 16))")
}

// ==== dump GameState 的 MonoClass 结构 ====
if let gs = found["GameState"] {
    guard let gmem = read(gs, 0x100) else { exit(1) }
    print("\n=== GameState MonoClass 结构 dump（0x100 字节）===")
    for off in stride(from: 0, to: 0x100, by: 8) {
        let p = gmem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
        guard p != 0 else { continue }
        var desc = ""
        if p >= monoTextLo && p < monoTextHi {
            desc = "mono代码段"
        } else if isPtr(p) {
            if let s = cStr(p, max: 48) { desc = "str='\(s)'" }
            let m = read(p, 16).map {
                "\($0.withUnsafeBytes { $0.load(as: UInt64.self) })"
            } ?? "?"
            desc += " →[\(m)]"
            if p == image { desc = "本image!" }
            if allClasses.contains(where: { $0.addr == p }) { desc = "另一MonoClass!" }
        } else {
            desc = "raw=\(p)"
        }
        print(String(format: "+0x%02X %@", off, desc))
    }
} else {
    print("\n未找到 GameState（桶头只覆盖部分类，需要链遍历或更大偏移范围扫描）")
}
