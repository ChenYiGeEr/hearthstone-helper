import Foundation
import AppKit
import Darwin

// 阶段十二：读 GameState 静态字段（s_instance 等）
// 路线：MonoClass.fields 数组发现 → MonoClassField 布局实证 → vtable data → s_instance 值

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
func u32(_ d: Data, _ o: Int) -> UInt32 { d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) } }

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

// ==== GameState MonoClass + MonoVTable（堆扫）====
var gsClass: UInt64 = 0
var gsVtable: UInt64 = 0
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        for k in 0..<words {
            guard k + 7 < words else { break }
            if gsClass == 0, ptr[k + 7] == image {
                let p = chunkBase + UInt64(k * 8)
                let np = ptr[k + 8]
                if isPtr(np), let s = cStr(np), s == "GameState" { gsClass = p }
            }
            if gsVtable == 0, ptr[k] != 0, ptr[k] < 0x8000_0000_0000, ptr[k] > 0x10000, ptr[k + 2] == domain {
                // 延后验证 klass 名字
                let w = chunkBase + UInt64(k * 8)
                if let cm = read(ptr[k], 0x48), u64(cm, 0x38) == image, let n = cStr(u64(cm, 0x40)), n == "GameState" {
                    gsVtable = w
                }
            }
        }
    }
    return gsClass == 0 || gsVtable == 0
}
guard gsClass != 0, gsVtable != 0 else { print("类或 vtable 未找到"); exit(1) }
print("✓ GameState 类 @ \(String(gsClass, radix: 16))  vtable @ \(String(gsVtable, radix: 16))")

// ==== 发现 fields 数组：扫类的 0x100 指针，找内容为 {name→已知字段名} 步进的数组 ====
guard let cmem = read(gsClass, 0x100) else { exit(1) }
let knownFields = Set(["m_entityMap", "m_playerMap", "m_gameEntity", "s_instance", "m_options", "m_powerProcessor"])
var fieldsArray: UInt64 = 0
var fieldEntryLayout = (nameOff: 0, offsetOff: 0)  // MonoClassField 内 name/offset 位置
for off in stride(from: 0x60, to: 0x100, by: 8) {
    let p = u64(cmem, off)
    guard isPtr(p), p != image else { continue }
    guard let am = read(p, 0x800) else { continue }
    // 尝试条目步长 0x20，name 在 +0 或 +8
    for stride in [0x20] {
        for nameOff in [0, 8] {
            var hits = 0
            var firstOffset: UInt32 = 0
            for e in 0..<24 {
                let base = e * stride
                guard base + stride <= am.count else { break }
                let np = u64(am, base + nameOff)
                guard isPtr(np), let s = cStr(np, max: 48) else { break }
                guard knownFields.contains(s) || s.hasPrefix("m_") || s.hasPrefix("s_") || s.hasPrefix("<") else { break }
                hits += 1
                if e == 0 { firstOffset = 0xFFFFFFFF }
            }
            if hits >= 3 {
                fieldsArray = p
                fieldEntryLayout = (nameOff, 0)
                print("✓ fields 数组候选 @ \(String(p, radix: 16)) (类+0x\(String(off, radix: 16)))，条目 name@+\(nameOff)，命中 \(hits)")
                break
            }
        }
        if fieldsArray != 0 { break }
    }
    if fieldsArray != 0 { break }
}
guard fieldsArray != 0 else { print("fields 数组未发现——dump 类 0x60~0xF8 供人工分析"); exit(1) }

// ==== MonoClassField 布局实证：name 位置已知，找 offset 位置 ====
guard let fam = read(fieldsArray, 24 * 0x20) else { exit(1) }
print("\n=== 前 3 个字段条目 dump ===")
for e in 0..<3 {
    print("条目 \(e):", (0..<4).map { String(format: "+%02X %016llx", $0*8, u64(fam, e*0x20 + $0*8)) }.joined(separator: "  "))
}
// name@nameOff；offset 应是 +0x18 附近的 u32（instance 字段偏移递增，static 字段偏移独立）
var fieldInfo: [(String, UInt32)] = []
for e in 0..<90 {
    let base = e * 0x20
    guard base + 0x20 <= fam.count else { break }
    let np = u64(fam, base + fieldEntryLayout.nameOff)
    guard isPtr(np), let s = cStr(np, max: 48) else { continue }
    let offCandidates: [Int] = [0x18, 0x14, 0x1C, 0x10]
    var off: UInt32 = 0xFFFFFFFF
    for oc in offCandidates {
        let v = u32(fam, base + oc)
        if v < 0x1000 { off = v; break }
    }
    fieldInfo.append((s, off))
}
print("\n=== 字段名 → 偏移（前 90 项）===")
for (n, o) in fieldInfo {
    print("  \(n) @ +0x\(String(o, radix: 16))")
}

// ==== vtable data 候选扫描：找 s_instance 值 ====
let staticName = "s_instance"
if let si = fieldInfo.first(where: { $0.0 == staticName }) {
    print("\n\(staticName) 偏移 = +0x\(String(si.1, radix: 16))")
    guard let vm = read(gsVtable, 0x100) else { exit(1) }
    for x in stride(from: 0x18, to: 0x100, by: 8) {
        let q = u64(vm, x)
        guard isPtr(q), q != gsClass, !(q >= mono && q < mono + 0x320000) else { continue }
        guard let qm = read(q, 0x400) else { continue }
        if Int(si.1) + 8 <= qm.count {
            let v = u64(qm, Int(si.1))
            if v == 0 { continue }
            // 验证值是 GameState 实例：[v]==gsVtable
            if let t = read(v, 8) {
                let vt = u64(t, 0)
                if vt == gsVtable {
                    print("★ vtable+0x\(String(x, radix: 16)) → \(String(q, radix: 16)): s_instance = \(String(v, radix: 16))（[v]==GameState vtable ✓）")
                }
            }
        }
    }
}
print("\n完成")
