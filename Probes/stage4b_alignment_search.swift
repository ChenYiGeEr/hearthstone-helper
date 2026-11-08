import Foundation
import AppKit
import Darwin

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
    guard b.count >= 2, b.count <= 90 else { return nil }
    return String(bytes: b, encoding: .utf8)
}
func isPtr(_ p: UInt64) -> Bool { p > 0x10000 && p < 0x8000_0000_0000 }

// 附加 → 根域 → Assembly-CSharp image → BSJB → strings base（复用已验证的链路）
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
print("✓ mono @", String(mono, radix: 16))
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
guard let image else { print("no image"); exit(1) }
print("✓ image @", String(image, radix: 16))
guard let imem = read(image, 0xC00) else { exit(1) }
var metaRoot: UInt64?
for off in stride(from: 0, to: 0xC00, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard p > 0x10000, p < 0x8000_0000_0000 else { continue }
    guard let head = read(p, 4) else { continue }
    if head.withUnsafeBytes { $0.load(as: UInt32.self) } == 0x424A5342 { metaRoot = p; break }
}
guard let metaRoot else { print("no BSJB"); exit(1) }
print("✓ BSJB @", String(metaRoot, radix: 16))
guard let meta = read(metaRoot, 0x400) else { exit(1) }
let vlen = Int(meta.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
var off2 = 16 + vlen
if off2 % 4 != 0 { off2 += 4 - off2 % 4 }
let streamCount = Int(meta.withUnsafeBytes { $0.load(fromByteOffset: off2 + 2, as: UInt16.self) })
var so = off2 + 4
var stringsOff = 0, stringsSize = 0, tildeOff = 0
for _ in 0..<streamCount {
    let sOff = meta.withUnsafeBytes { $0.load(fromByteOffset: so, as: UInt32.self) }
    let sSize = meta.withUnsafeBytes { $0.load(fromByteOffset: so + 4, as: UInt32.self) }
    var ns = so + 8; var ne = ns
    while ne < meta.count, meta[ne] != 0 { ne += 1 }
    let name = String(bytes: meta[ns..<ne], encoding: .utf8) ?? "?"
    if name == "#Strings" { stringsOff = Int(sOff); stringsSize = Int(sSize) }
    if name == "#~" { tildeOff = Int(sOff) }
    so = ne + 1
    if so % 4 != 0 { so += 4 - so % 4 }
}
print("✓ strings off", stringsOff, "size", stringsSize, "tilde off", tildeOff)
let stringsBase = metaRoot + UInt64(stringsOff)
let tildeBase = metaRoot + UInt64(tildeOff)

// ==== #~ 表头 → 计算 TypeDef 数据起点（stage4 公式）====
guard let tilde = read(tildeBase, 512) else { print("read tilde fail"); exit(1) }
let heapSizes = tilde.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt8.self) }
let validMask = tilde.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
let strIdxSz: Int = heapSizes & 1 != 0 ? 4 : 2
let guidIdxSz: Int = heapSizes & 2 != 0 ? 4 : 2
var rowCounts: [Int] = []
var ord = 0
for bit in 0..<64 where validMask & (1 << UInt64(bit)) != 0 {
    let n = tilde.withUnsafeBytes { $0.load(fromByteOffset: 24 + ord * 4, as: UInt32.self) }
    rowCounts.append(Int(n))
    ord += 1
}
print("✓ 堆宽度 str=\(strIdxSz) guid=\(guidIdxSz)，表数 \(rowCounts.count)")
guard rowCounts.count > 2 else { print("表数不足"); exit(1) }

// bit 位号 = ECMA-335 表号；建立 表号→行数 映射
var tableRows: [Int: Int] = [:]
var bit = 0
for t in 0..<64 where validMask & (1 << UInt64(t)) != 0 {
    tableRows[t] = rowCounts[bit]
    bit += 1
}
let rows = { (t: Int) in tableRows[t] ?? 0 }
print("✓ 表行数: Module \(rows(0x00)) TypeRef \(rows(0x01)) TypeDef \(rows(0x02)) Field \(rows(0x04)) MethodDef \(rows(0x06)) TypeSpec \(rows(0x1B)) AssemblyRef \(rows(0x23)) ModuleRef \(rows(0x1A))")

// 编码索引宽度：相关表最大行数 ≥ 2^(16-tag位) → 4 字节，否则 2 字节
let coded2 = { (ts: [Int]) -> Int in ts.map { rows($0) }.max()! < (1 << (16 - 2)) ? 2 : 4 }
let resolutionScopeSz = coded2([0x00, 0x1A, 0x23, 0x01])   // Module/ModuleRef/AssemblyRef/TypeRef
let typeDefOrRefSz = coded2([0x02, 0x01, 0x1B])             // TypeDef/TypeRef/TypeSpec
let simpleIdx = { (t: Int) -> Int in rows(t) < (1 << 16) ? 2 : 4 }
let fieldListSz = simpleIdx(0x04)
let methodListSz = simpleIdx(0x06)
print("✓ 索引宽度: ResScope=\(resolutionScopeSz) DefOrRef=\(typeDefOrRefSz) FieldList=\(fieldListSz) MethodList=\(methodListSz)")

let moduleRows = rows(0x00), typeRefRows = rows(0x01), typeDefRows = rows(0x02)
let moduleRowSize = 2 + strIdxSz + guidIdxSz * 3
let typeRefRowSize = resolutionScopeSz + strIdxSz * 2
let typeDefRowSizeExact = 4 + strIdxSz * 2 + typeDefOrRefSz + fieldListSz + methodListSz
let typeDefDataStart = 24 + rowCounts.count * 4 + moduleRows * moduleRowSize + typeRefRows * typeRefRowSize
print("✓ 计算 TypeDef 起点 = tilde+0x\(String(typeDefDataStart, radix: 16))，行大小 \(typeDefRowSizeExact)，TypeDef \(typeDefRows) 行")

// 对齐搜索：锚定计算出的 TypeDef 起点，扫描 ±N 偏移与行大小组合，按有效类名率打分
// 校验签名：第 0 行 TypeDef 恒为 <Module>
print("=== 对齐搜索 ===")
print("格式: start_offset row_size → valid/total → 前5个类名")
var best = (valid: 0, offset: 0, rowSize: 0)
for startOff in stride(from: -36, through: 36, by: 4) {
    for rowSz in [16, 18, 20, 22, 24] {
        let anchor = Int64(typeDefDataStart) + Int64(startOff)
        guard anchor > 0 else { continue }
        let tdStart = tildeBase + UInt64(anchor)
        let checkCount = min(50, typeDefRows)
        guard let tdData = read(tdStart, checkCount * rowSz) else { continue }
        var valid = 0
        var seen = Set<String>()
        var samples: [String] = []
        for row in 0..<checkCount {
            let base = row * rowSz
            guard base + 12 <= tdData.count else { break }
            let nameIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: UInt32.self) }
            let nsIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 4 + strIdxSz, as: UInt32.self) }
            guard nameIdx > 0, nameIdx < UInt32(stringsSize), nsIdx < UInt32(stringsSize) else { continue }
            let name = cStr(stringsBase + UInt64(nameIdx), max: 64) ?? ""
            let ns = cStr(stringsBase + UInt64(nsIdx), max: 64) ?? ""
            let ok = name.count > 2
                && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                && (nsIdx == 0 || (ns.count > 2 && ns.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })))
                && seen.insert(name).inserted
            if ok {
                valid += 1
                if samples.count < 5 { samples.append(ns.isEmpty ? name : "\(ns).\(name)") }
            }
        }
        if valid > best.valid && valid > 10 {
            best = (valid, startOff, rowSz)
            print("  offset=\(startOff) rowSize=\(rowSz) → \(valid)/\(checkCount) [\(samples.joined(separator: ", "))]")
        }
    }
}
print("\n★ 最佳: offset=\(best.offset) rowSize=\(best.rowSize) → \(best.valid)/50")
