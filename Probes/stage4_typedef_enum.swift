import Foundation
import AppKit
import Darwin

// 阶段四：枚举 Assembly-CSharp 全部 TypeDef 类名
// 前置：阶段一二三已验证的附着/定位/BSJB 解析链

// ==== 基础设施（阶段一验证）====
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
func cStr(_ addr: UInt64, max: Int = 128) -> String? {
    guard let d = read(addr, max) else { return nil }
    let b = d.prefix { $0 != 0 }
    guard b.count >= 1 else { return nil }
    return String(bytes: b, encoding: .utf8)
}
func isPtr(_ p: UInt64) -> Bool { p > 0x10000 && p < 0x8000_0000_0000 }

// ==== 定位 mono → 根域 → Assembly-CSharp image ====
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
var csharpImage: UInt64?
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
            if s == "Assembly-CSharp.dll" { csharpImage = img; break }
        }
        if csharpImage != nil { break }
    }
    if csharpImage != nil { break }
    if next == 0 { break }
    node = next
}
guard let csharpImage else { print("no Assembly-CSharp"); exit(1) }
print("✓ Assembly-CSharp image @ \(String(csharpImage, radix: 16))")

// ==== BSJB 元数据根 ====
guard let imem = read(csharpImage, 0xC00) else { exit(1) }
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
var tildeOff = 0, tildeSize = 0, stringsOff = 0, stringsSize = 0
for _ in 0..<streamCount {
    let sOff = meta.withUnsafeBytes { $0.load(fromByteOffset: so, as: UInt32.self) }
    let sSize = meta.withUnsafeBytes { $0.load(fromByteOffset: so + 4, as: UInt32.self) }
    var ns = so + 8; var ne = ns
    while ne < meta.count, meta[ne] != 0 { ne += 1 }
    let name = String(bytes: meta[ns..<ne], encoding: .utf8) ?? "?"
    if name == "#~" { tildeOff = Int(sOff); tildeSize = Int(sSize) }
    if name == "#Strings" { stringsOff = Int(sOff); stringsSize = Int(sSize) }
    so = ne + 1
    if so % 4 != 0 { so += 4 - so % 4 }
}
let stringsBase = metaRoot + UInt64(stringsOff)
let tildeBase = metaRoot + UInt64(tildeOff)
print("✓ #~ @ +0x\(String(tildeOff, radix: 16)) #Strings @ +0x\(String(stringsOff, radix: 16)) size=\(stringsSize)")

// ==== #~ 表头 ====
guard let tilde = read(tildeBase, 512) else { exit(1) }
let heapSizes = tilde.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt8.self) }
let validMask = tilde.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
let strWide = heapSizes & 1 != 0
let strIdxSz = strWide ? 4 : 2
var rowCounts: [Int] = []
var ord = 0
for bit in 0..<64 where validMask & (1 << UInt64(bit)) != 0 {
    let n = tilde.withUnsafeBytes { $0.load(fromByteOffset: 24 + ord * 4, as: UInt32.self) }
    rowCounts.append(Int(n))
    ord += 1
}
print("✓ TypeDef \(rowCounts[2]), Field \(rowCounts[3]), MethodDef \(rowCounts[4])")

// ==== TypeDef 表遍历 ====
// 已由 stage4b 校准确认：TypeDef 数据起点 = tilde+0x573C，行大小 22
// 布局: flags(4) name(4) ns(4) extends(2) fieldList(4) methodList(4)
// （Field 91786 / MethodDef 113059 均 > 65535 → 简单索引 4 字节）
let typeDefRows = rowCounts[2]
let typeDefRowSize = 22
let typeDefDataStartOff = 0x573C
print("✓ TypeDef 数据 @ tilde+0x\(String(typeDefDataStartOff, radix: 16)) 行大小 \(typeDefRowSize)（stage4b 校准值）")

print("\n=== TypeDef 类名全量枚举（rowSize=\(typeDefRowSize)）===")
let tdReadSize = typeDefRows * typeDefRowSize
guard let tdData = read(tildeBase + UInt64(typeDefDataStartOff), tdReadSize) else { exit(1) }

var gameClasses: [(Int, String)] = []
var allNames: [String] = []
var namespaces = Set<String>()
var validCount = 0

for row in 0..<typeDefRows {
    let base = row * typeDefRowSize
    guard base + typeDefRowSize <= tdData.count else { break }
    let nameIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 4, as: UInt32.self) }
    let nsIdx = tdData.withUnsafeBytes { $0.load(fromByteOffset: base + 8, as: UInt32.self) }
    guard nameIdx > 0, nameIdx < UInt32(stringsSize), nsIdx < UInt32(stringsSize) else { continue }
    let name = cStr(stringsBase + UInt64(nameIdx), max: 96) ?? "?"
    if name == "<Module>" { continue }
    let ns = nsIdx == 0 ? "" : (cStr(stringsBase + UInt64(nsIdx), max: 96) ?? "?")
    guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" }) else { continue }
    validCount += 1
    if !ns.isEmpty { namespaces.insert(ns) }
    let fullName = ns.isEmpty ? name : "\(ns).\(name)"
    allNames.append(fullName)
    let lower = fullName.lowercased()
    if lower.contains("game") || lower.contains("zone") || lower.contains("hand") || lower.contains("deck") || lower.contains("player") || lower.contains("entity") || lower.contains("card") || lower.contains("match") || lower.contains("turn") {
        gameClasses.append((row, fullName))
    }
}
print("有效类名: \(validCount) / \(typeDefRows)，命名空间 \(namespaces.count) 个")

print("\n=== 命名空间样本（前 30）===")
for ns in namespaces.sorted().prefix(30) { print("  \(ns)") }

print("\n=== 游戏状态相关类（\(gameClasses.count) 个，前 60）===")
for (row, name) in gameClasses.prefix(60) {
    print("  [\(row)] \(name)")
}

let outPath = "/tmp/assembly_csharp_classes.txt"
try? allNames.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
try? namespaces.sorted().joined(separator: "\n").write(toFile: "/tmp/assembly_csharp_namespaces.txt", atomically: true, encoding: .utf8)
print("\n全部类名已写入 \(outPath)（\(allNames.count) 个）")
