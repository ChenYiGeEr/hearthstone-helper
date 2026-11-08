import Foundation
import AppKit
import Darwin

// 阶段十一：从元数据 Field 表读核心类的字段（名字 + static 标志 + fieldList 行号区间）
// TypeDef.fieldList = Field 表起始行（1-based），下一行的 fieldList = 结束

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
guard let imem = read(image, 0xC00) else { exit(1) }
var metaRoot: UInt64?
for off in stride(from: 0, to: 0xC00, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard p > 0x10000, p < 0x8000_0000_0000 else { continue }
    guard let head = read(p, 4) else { continue }
    if head.withUnsafeBytes { $0.load(as: UInt32.self) } == 0x424A5342 { metaRoot = p; break }
}
guard let metaRoot else { print("no BSJB"); exit(1) }
guard let meta = read(metaRoot, 0x400) else { exit(1) }
let vlen = Int(meta.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
var off2 = 16 + vlen
if off2 % 4 != 0 { off2 += 4 - off2 % 4 }
let streamCount = Int(meta.withUnsafeBytes { $0.load(fromByteOffset: off2 + 2, as: UInt16.self) })
var so = off2 + 4
var tildeOff = 0, stringsOff = 0, stringsSize = 0
for _ in 0..<streamCount {
    let sOff = meta.withUnsafeBytes { $0.load(fromByteOffset: so, as: UInt32.self) }
    let sSize = meta.withUnsafeBytes { $0.load(fromByteOffset: so + 4, as: UInt32.self) }
    let ns = so + 8; var ne = ns
    while ne < meta.count, meta[ne] != 0 { ne += 1 }
    let name = String(bytes: meta[ns..<ne], encoding: .utf8) ?? "?"
    if name == "#Strings" { stringsOff = Int(sOff); stringsSize = Int(sSize) }
    if name == "#~" { tildeOff = Int(sOff) }
    so = ne + 1
    if so % 4 != 0 { so += 4 - so % 4 }
}
let stringsBase = metaRoot + UInt64(stringsOff)
let tildeBase = metaRoot + UInt64(tildeOff)
guard let tilde = read(tildeBase, 512) else { exit(1) }
let validMask = tilde.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
var rowCounts: [Int] = []
var ord = 0
for bit in 0..<64 where validMask & (1 << UInt64(bit)) != 0 {
    rowCounts.append(Int(tilde.withUnsafeBytes { $0.load(fromByteOffset: 24 + ord * 4, as: UInt32.self) }))
    ord += 1
}
let typeDefRows = rowCounts[2]
let fieldRows = rowCounts[3]      // Field 表（FieldPtr 缺席）
let typeDefRowSize = 22
let typeDefDataStart = 0x573C     // stage4b 校准
let fieldDataStart = typeDefDataStart + typeDefRows * typeDefRowSize  // FieldPtr 缺席 → 紧随 TypeDef
print("✓ TypeDef \(typeDefRows) 行 Field \(fieldRows) 行，Field 表 @ tilde+0x\(String(fieldDataStart, radix: 16))")

// Field 行：flags(2) + name(4) + signature(4) = 10 字节（str=4, blob=4）
let fieldRowSize = 10
guard let fmem = read(tildeBase + UInt64(fieldDataStart), min(fieldRows * fieldRowSize, 0x200000)) else { exit(1) }
func fieldName(_ row1: Int) -> String {
    let base = (row1 - 1) * fieldRowSize
    guard base + 10 <= fmem.count else { return "?" }
    let flags = fmem.withUnsafeBytes { $0.load(fromByteOffset: base, as: UInt16.self) }
    let nameIdx = fmem.withUnsafeBytes { $0.load(fromByteOffset: base + 2, as: UInt32.self) }
    guard nameIdx > 0, Int(nameIdx) < stringsSize else { return "?" }
    return (cStr(stringsBase + UInt64(nameIdx), max: 96) ?? "?") + (flags & 0x0010 != 0 ? " [static]" : "")
}

// TypeDef 全量枚举定位目标类并解析 fieldList 区间
guard let tdData = read(tildeBase + UInt64(typeDefDataStart), typeDefRows * typeDefRowSize) else { exit(1) }
let targets = Set(["GameState", "Gameplay", "ZoneMgr", "Player", "Entity", "Zone", "EntityDef", "GameMgr", "Card", "ZonePlay", "ZoneHand", "ZoneDeck"])
var rows: [(Int, String, UInt32, UInt32)] = []  // row1, name, fieldList, methodList
for row in 0..<typeDefRows {
    let base = row * typeDefRowSize
    let nameIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: UInt32.self) }
    let nsIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: UInt32.self) }
    let fieldList = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 14, as: UInt32.self) }
    guard nameIdx > 0, Int(nameIdx) < stringsSize else { continue }
    let name = cStr(stringsBase + UInt64(nameIdx), max: 96) ?? "?"
    if targets.contains(name) {
        let ns = nsIdx == 0 ? "" : (cStr(stringsBase + UInt64(nsIdx), max: 96) ?? "")
        rows.append((row + 1, ns.isEmpty ? name : "\(ns).\(name)", fieldList, 0))
    }
}
// methodList 用于推下一行边界（这里直接用下一行 fieldList）
for (i, r) in rows.enumerated() {
    let nextRow = r.0  // 1-based TypeDef 行号 → 下一行 fieldList
    if r.0 < typeDefRows {
        let nb = r.0 * typeDefRowSize
        let nextFieldList = tdData.withUnsafeBytes { $0.load(fromByteOffset: nb + 14, as: UInt32.self) }
        let end = nextFieldList > 0 ? Int(nextFieldList) - 1 : Int(fieldRows)
        print("\n=== [TypeDef 行 \(r.0)] \(r.1) — fieldList \(r.2)...\(end) ===")
        for f in Int(r.2)...max(Int(r.2), end) {
            print("  \(fieldName(f))")
        }
    }
}
print("\n完成")
