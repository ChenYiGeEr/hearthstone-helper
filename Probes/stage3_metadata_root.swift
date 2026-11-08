import Foundation
import AppKit
import Darwin

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { exit(1) }
var task: mach_port_t = 0
let handle = dlopen("HearthMirror.framework/HearthMirror", RTLD_NOW) ?? dlopen(nil, RTLD_NOW)
if let handle, let sym = dlsym(handle, "acquireTaskportRight") {
    _ = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)()
}
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else { exit(1) }
func read(_ addr: UInt64, _ size: Int) -> Data? {
    var p: vm_offset_t = 0; var c: mach_msg_type_number_t = 0
    guard vm_read(task, vm_address_t(addr), vm_size_t(size), &p, &c) == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, p, vm_size_t(c)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: p)!, count: Int(c))
}
var info = task_dyld_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / 4)
_ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, 17, $0, &count) } }
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
guard let mono else { exit(1) }
let exp = mono + 0x11853c
guard let ins = read(exp, 8) else { exit(1) }
let i1 = ins.withUnsafeBytes { $0.load(as: UInt32.self) }, i2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
var imm = Int((((i1 >> 5) & 0x7FFFF) << 2) | ((i1 >> 29) & 0x3))
if imm & (1 << 20) != 0 { imm -= (1 << 21) }
let domain = read((exp & ~0xFFF) + UInt64(imm * 4096) + UInt64(((i2 >> 10) & 0xFFF) * 8), 8)!.withUnsafeBytes { $0.load(as: UInt64.self) }
guard let dm = read(domain, 0x2000) else { exit(1) }

// Assembly-CSharp image（+0xB0 链）
var node = dm.withUnsafeBytes { $0.load(fromByteOffset: 0xB0, as: UInt64.self) }
var image: UInt64?
var assembly: UInt64?
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
            if s.isEmpty { continue }
            if s == "Assembly-CSharp.dll" {
                image = img; assembly = data; break
            }
        }
        if image != nil { break }
    }
    if image != nil { break }
    if next == 0 { break }
    node = next
}
guard let image, let assembly else { print("no image"); exit(1) }
print("✓ Assembly-CSharp image @ \(String(image, radix: 16)), assembly @ \(String(assembly, radix: 16))")

// ===== 扫描 MonoImage 全部指针字段 → 找 BSJB 元数据根 =====
guard let imem = read(image, 0xC00) else { exit(1) }
for off in stride(from: 0, to: 0xC00, by: 8) {
    let p = imem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard p > 0x10000, p < 0x8000_0000_0000 else { continue }
    guard let head = read(p, 24) else { continue }
    let sig = head.withUnsafeBytes { $0.load(as: UInt32.self) }
    guard sig == 0x424A5342 else { continue } // BSJB
    let vlen = head.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
    print("✓ BSJB 元数据根: image+0x\(String(off, radix: 16)) → \(String(p, radix: 16))，版本串长 \(vlen)")

    // 解析流头
    var off2 = 16 + Int(vlen)
    if off2 % 4 != 0 { off2 += 4 - off2 % 4 }
    let streams = Int(head.withUnsafeBytes { $0.load(fromByteOffset: off2 + 2 - 16 + 16, as: UInt16.self) })
    // 重新读大块以解析流
    guard let big = read(p, 0x2000) else { continue }
    let streams2 = Int(big.withUnsafeBytes { $0.load(fromByteOffset: off2 + 2, as: UInt16.self) })
    print("  流数量: \(streams2)")
    var tildeStreamOffset = 0, tildeStreamSize = 0
    var stringsStreamOffset = 0, stringsStreamSize = 0
    var so = off2 + 4
    for _ in 0..<streams2 {
        // ECMA-335 II.24.2.2: Offset(4) + Size(4) + Name(padded)
        let sOff = big.withUnsafeBytes { $0.load(fromByteOffset: so, as: UInt32.self) }
        let sSize = big.withUnsafeBytes { $0.load(fromByteOffset: so + 4, as: UInt32.self) }
        var nameStart = so + 8
        var nameEnd = nameStart
        while nameEnd < big.count, big[nameEnd] != 0 { nameEnd += 1 }
        let name = String(bytes: big[nameStart..<nameEnd], encoding: .utf8) ?? "?"
        print("    流 \(name): offset=\(sOff) size=\(sSize)")
        so = nameEnd + 1
        if so % 4 != 0 { so += 4 - so % 4 }
        if name == "#~" { tildeStreamOffset = Int(sOff); tildeStreamSize = Int(sSize) }
        if name == "#Strings" { stringsStreamOffset = Int(sOff); stringsStreamSize = Int(sSize) }
    }

    // ===== #~ 表头解析：HeapSizes 位标志决定索引宽度 =====
    guard let tilde = read(p + UInt64(tildeStreamOffset), 64) else { exit(1) }
    let reserved = tilde.withUnsafeBytes { $0.load(as: UInt32.self) }
    let majorV = tilde.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt8.self) }
    let minorV = tilde.withUnsafeBytes { $0.load(fromByteOffset: 5, as: UInt8.self) }
    let heapSizes = tilde.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt8.self) }
    let validMask = tilde.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
    let sortedMask = tilde.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
    print("  #~ 表头: v\(majorV).\(minorV) heapSizes=\(heapSizes) valid=\(String(validMask, radix: 16))")
    let strIdxWide = heapSizes & 1 != 0     // #Strings 索引 4 字节
    let guidIdxWide = heapSizes & 2 != 0
    let blobIdxWide = heapSizes & 4 != 0
    print("  索引宽度: strings=\(strIdxWide ? 4 : 2) guid=\(guidIdxWide ? 4 : 2) blob=\(blobIdxWide ? 4 : 2)")

    // 表行数：validMask 每一位对应一个表
    var rowCounts: [Int] = []
    for bit in 0..<64 where validMask & (1 << UInt64(bit)) != 0 {
        let off = 24 + bit * 4
        let n = tilde.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }
        rowCounts.append(Int(n))
    }
    print("  表数量: \(rowCounts.count)")

    // ECMA-335 表编号（部分）：0x00 Module, 0x01 TypeRef, 0x02 TypeDef, 0x04 Field, 0x06 MethodDef
    // TypeDef 在 validMask 中的位序（bit index = 表编号）
    let typeDefBit = 2, fieldBit = 4, methodDefBit = 6
    guard typeDefBit < rowCounts.count else { print("无 TypeDef 表"); exit(1) }
    let typeDefRows = rowCounts[typeDefBit]
    let fieldRows = fieldBit < rowCounts.count ? rowCounts[fieldBit] : 0
    let methodRows = methodDefBit < rowCounts.count ? rowCounts[methodDefBit] : 0
    print("  TypeDef 行数: \(typeDefRows), Field 行数: \(fieldRows), MethodDef 行数: \(methodRows)")

    // ===== 计算行大小以定位 TypeDef 表数据 =====
    // 表数据起点 = 表头之后（24 + 表数×4），堆数据跟随其后
    var tablesOffset = 24 + rowCounts.count * 4
    // 各表行大小的计算需要按 ECMA-335 顺序逐表推进——完整实现较长，
    // 这里用已知近似：TypeDef 行（64 位）= flags(4) + nameIdx(2/4) + nsIdx(2/4)
    //   + extends(coded 2/4) + fieldList(2/4) + methodList(2/4) ≈ 24 字节
    // 精确做法需要每个索引列的宽度判定。先探：TypeDef 表起始 = 前面所有表行数×行大小之和
    // （完整实现见下一迭代，这里用暴力法：直接在 #~ 流里搜字符串堆引用定位 Game 类名）

    // ===== 全堆字符串扫描：T5 类命名侦查 =====
    var strings: [(UInt32, String)] = [(0, "")]  // 偏移 0 = 空串
    let stringsBase = image + UInt64(stringsStreamOffset)
    var cur = stringsBase + 1
    var curOff: UInt32 = 1
    let heapEnd = stringsBase + UInt64(stringsStreamSize)
    while cur < heapEnd {
        guard let d = read(cur, 512) else { break }
        var i = 0
        while i < d.count {
            if d[i] == 0 { break }
            i += 1
        }
        if i == 0 { cur += 1; curOff += 1; continue }
        let s = String(bytes: d.prefix(i), encoding: .utf8) ?? ""
        strings.append((curOff, s))
        cur += UInt64(i + 1)
        curOff += UInt32(i + 1)
    }
    print("  字符串堆总数: \(strings.count)")
    let keywords = ["Game", "Zone", "Hand", "Deck", "Player", "Entity", "GameState", "Turn"]
    for kw in keywords {
        let matches = strings.filter { $0.1 == kw || $0.1.hasPrefix(kw) }.prefix(6)
        let exact = strings.first { $0.1 == kw }
        let exactMark = exact != nil ? " ✓精确" : ""
        print("  [\(kw)]\(exactMark) 前缀匹配 \(matches.count): " + matches.map { "\($0.1)(@\($0.0))" }.joined(separator: " "))
    }
    }
    exit(0)