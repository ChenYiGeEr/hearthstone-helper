import Foundation
import AppKit
import Darwin

// 阶段十四：己方侧判定（Player.m_local）+ 手牌对账闭环
// 复用 stage13 配方；聚焦 ZoneHand controller → Player → m_local

setbuf(stdout, nil)
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
func i32(_ d: Data, _ o: Int) -> Int32 { d.withUnsafeBytes { $0.load(fromByteOffset: o, as: Int32.self) } }

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

let targets = Set(["GameState", "ZoneMgr", "Player", "Zone"])
var classByName: [String: UInt64] = [:]
var vtByClass: [String: UInt64] = [:]
var klassCache: [UInt64: String] = [:]
func className(_ kl: UInt64) -> String {
    if let n = klassCache[kl] { return n }
    guard let km = read(kl, 0x48), u64(km, 0x38) == image, let s = cStr(u64(km, 0x40)) else {
        klassCache[kl] = "?"; return "?"
    }
    klassCache[kl] = s
    return s
}
forEachRegion { base, size in
    scanChunks(base, size) { chunkBase, ptr, words in
        for k in 0..<words {
            guard k + 7 < words else { break }
            if ptr[k + 7] == image, classByName.count < targets.count {
                let np = ptr[k + 8]
                if isPtr(np), let s = cStr(np), targets.contains(s), classByName[s] == nil {
                    classByName[s] = chunkBase + UInt64(k * 8)
                }
            }
            if k + 2 < words, ptr[k + 2] == domain, isPtr(ptr[k]) {
                let n = className(ptr[k])
                if targets.contains(n), vtByClass[n] == nil { vtByClass[n] = chunkBase + UInt64(k * 8) }
            }
        }
    }
    return true
}
print("✓ 类+vtable：\(targets.sorted().map { n in "\(n):\(classByName[n] != nil && vtByClass[n] != nil ? "✓" : "✗")" }.joined(separator: " "))")

var fieldsCache: [UInt64: [String: Int]] = [:]
func fields(_ klass: UInt64) -> [String: Int] {
    if let f = fieldsCache[klass] { return f }
    var map: [String: Int] = [:]
    if let km = read(klass, 0x98), isPtr(u64(km, 0x90)), let fm = read(u64(km, 0x90), 0x20 * 200) {
        for e in 0..<200 {
            let base = e * 0x20
            let np = u64(fm, base + 8)
            guard isPtr(np), let s = cStr(np, max: 48) else { break }
            map[s] = Int(i32(fm, base + 0x18))
        }
    }
    fieldsCache[klass] = map
    return map
}
func staticValue(_ clsName: String, _ fieldName: String) -> UInt64? {
    guard let cls = classByName[clsName], let vt = vtByClass[clsName],
          let vm = read(vt, 0x80) else { return nil }
    let flags: UInt8 = vm.withUnsafeBytes { $0.load(fromByteOffset: 0x2F, as: UInt8.self) }
    guard (flags >> 2) & 1 == 1 else { return nil }
    guard let km = read(cls, 0x60) else { return nil }
    let slot = Int(i32(km, 0x54))
    let data = u64(vm, 0x48 + slot * 8)
    guard isPtr(data), let dm2 = read(data, 0x200) else { return nil }
    let off = fields(cls)[fieldName] ?? -1
    guard off >= 0, off + 8 <= 0x200 else { return nil }
    return u64(dm2, off)
}
func objClass(_ obj: UInt64) -> String? {
    guard isPtr(obj), let om = read(obj, 0x10), isPtr(u64(om, 0)),
          let vm = read(u64(om, 0), 0x10), isPtr(u64(vm, 0)) else { return nil }
    let n = className(u64(vm, 0))
    return n == "?" ? nil : n
}
func listItems(_ v: UInt64) -> [UInt64]? {
    guard isPtr(v), let m = read(v, 0x20), isPtr(u64(m, 0x10)) else { return nil }
    let sz = Int(Int32(bitPattern: u32(m, 0x18)))
    guard sz >= 0, sz < 100000 else { return nil }
    let arr = u64(m, 0x10)
    guard sz > 0, let vec = read(arr + 0x20, sz * 8) else { return [] }
    return (0..<sz).map { e in vec.withUnsafeBytes { raw in raw.load(fromByteOffset: e * 8, as: UInt64.self) } }
}

// ==== ZoneMgr → zones → hand controller Player → m_local ====
guard let zm = staticValue("ZoneMgr", "s_instance"), isPtr(zm) else {
    print("ZoneMgr.s_instance = null（不在对局）"); exit(0)
}
guard let zmc = classByName["ZoneMgr"], let zonesOff = fields(zmc)["m_zones"],
      let zmem = read(zm, zonesOff + 8), isPtr(u64(zmem, zonesOff)),
      let zones = listItems(u64(zmem, zonesOff)) else {
    print("m_zones 解析失败"); exit(1)
}
let zf = fields(classByName["Zone"]!)
let pf = fields(classByName["Player"]!)
print("✓ zones=\(zones.count)  Player 字段: m_local@+0x\(String(pf["m_local"] ?? -1, radix: 16)) m_name@+0x\(String(pf["m_name"] ?? -1, radix: 16)) m_side@+0x\(String(pf["m_side"] ?? -1, radix: 16))")
for z in zones where isPtr(z) {
    guard let n = objClass(z), n == "ZoneHand", let zmem2 = read(z, 0x100) else { continue }
    var count = -1
    if let co = zf["m_cards"], isPtr(u64(zmem2, co)), let l = listItems(u64(zmem2, co)) { count = l.count }
    let side = Int32(bitPattern: u32(zmem2, zf["m_Side"] ?? 0))
    guard let co = zf["m_controller"], isPtr(u64(zmem2, co)) else { continue }
    let player = u64(zmem2, co)
    guard let pmem = read(player, 0x200) else { continue }
    let localOff = pf["m_local"] ?? -1
    let nameOff = pf["m_name"] ?? -1
    let sideOff = pf["m_side"] ?? -1
    let localByte: UInt8 = localOff >= 0 ? pmem.withUnsafeBytes { $0.load(fromByteOffset: localOff, as: UInt8.self) } : 0xFF
    let playerSide = sideOff >= 0 ? Int32(bitPattern: u32(pmem, sideOff)) : -1
    var name = "?"
    if nameOff >= 0, isPtr(u64(pmem, nameOff)), let s = cStr(u64(pmem, nameOff)) { name = s }
    print("ZoneHand @ \(String(z, radix: 16)): cards=\(count) zoneSide=\(side) → Player \(String(player, radix: 16)) m_side=\(playerSide) m_local=\(localByte) name=\(name)")
}
print("\n完成（m_local=1 的一侧是己方；对照 UI 手牌数）")
