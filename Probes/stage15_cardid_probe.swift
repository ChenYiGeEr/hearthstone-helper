import Foundation
import AppKit
import Darwin

// 阶段十五：从内存读 Card 的 cardID —— 确定字段位置 + MonoString 布局
// 路径：ZoneMgr.s_instance → m_zones → 己方 ZoneDeck/ZoneHand → m_cards
//       → Card.m_entity → play Entity → 找 cardID 字符串字段
// 同时用 Player.m_name 校准 MonoString 布局（已知字符串）

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
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else { exit(1) }
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
func hex(_ v: UInt64) -> String { String(v, radix: 16) }
func hexDump(_ addr: UInt64, len: Int = 64) -> String {
    guard let d = read(addr, len) else { return "read fail" }
    return (0..<d.count).map { String(format: "%02x", d[$0]) }.joined(separator: " ")
}

// ==== boot: attach → domain → image ====
var info = task_dyld_info_data_t()
var dcnt = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / 4)
_ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(dcnt)) { task_info(task, 17, $0, &dcnt) } }
guard let h = read(info.all_image_info_addr, 16) else { exit(1) }
let ic = Int(h.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let ia = h.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
guard let arr = read(ia, ic * 24) else { exit(1) }
var monoBase: UInt64 = 0
for i in 0..<ic {
    let la = arr.withUnsafeBytes { $0.load(fromByteOffset: i*24, as: UInt64.self) }
    let fp = arr.withUnsafeBytes { $0.load(fromByteOffset: i*24+8, as: UInt64.self) }
    guard let pd = read(fp, 512) else { continue }
    if (String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? "").contains("libmonobdwgc") { monoBase = la; break }
}
guard monoBase != 0 else { print("no mono"); exit(1) }
let exp = monoBase + 0x11853c
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
print("✓ image @ \(hex(image))")

// ==== class discovery ====
func forEachRegion(_ body: (UInt64, UInt64) -> Bool) {
    var address: UInt64 = 0x1000
    while true {
        var size: mach_vm_size_t = 0
        var infoAddr = mach_vm_address_t(address)
        var basic = vm_region_basic_info_data_64_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
        var objectName: mach_port_t = 0
        let kr = withUnsafeMutablePointer(to: &basic) { ptr in
            mach_vm_region(task, &infoAddr, &size, vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
                UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCount, &objectName)
        }
        guard kr == KERN_SUCCESS else { return }
        defer { address = UInt64(infoAddr) + size }
        guard basic.protection & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }
        if !body(UInt64(infoAddr), size) { return }
    }
}

let wantClasses = Set(["ZoneMgr", "Zone", "Card", "Player", "GameState", "Entity", "EntityDef"])
var classByName: [String: [UInt64]] = [:]
forEachRegion { base, size in
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(8 * 1024 * 1024, size - offset))
        guard let buf = read(base + offset, n) else { break }
        buf.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            let words = n / 8
            for k in 0..<words {
                guard k + 8 < words else { break }
                if ptr[k + 7] == image {
                    let addr = base + offset + UInt64(k * 8)
                    let np = ptr[k + 8]
                    if isPtr(np), let s = cStr(np), wantClasses.contains(s) {
                        classByName[s, default: []].append(addr)
                    }
                }
            }
        }
        offset += UInt64(n)
    }
    return true
}
print("✓ candidates: \(classByName.map { "\($0.key)x\($0.value.count)" }.sorted().joined(separator: " "))")

var fieldsCache: [UInt64: [String: Int]] = [:]
func fields(_ klass: UInt64) -> [String: Int] {
    if let f = fieldsCache[klass] { return f }
    var map: [String: Int] = [:]
    var offs: [(String, Int)] = []
    if let km = read(klass, 0x98), isPtr(u64(km, 0x90)), let fm = read(u64(km, 0x90), 0x20 * 400) {
        for e in 0..<400 {
            let base = e * 0x20
            let np = u64(fm, base + 8)
            guard isPtr(np), let s = cStr(np, max: 96) else { break }
            let off = Int(i32(fm, base + 0x18))
            map[s] = off
            offs.append((s, off))
        }
    }
    fieldsCache[klass] = map
    return map
}
func allFields(_ klass: UInt64) -> [(String, Int)] {
    var out: [(String, Int)] = []
    var k = klass; var depth = 0; var seen = Set<UInt64>()
    while depth < 8 {
        if seen.contains(k) { break }; seen.insert(k)
        let f = fields(k)
        let sorted = f.sorted { $0.value < $1.value }
        for (n, o) in sorted { out.append((n, o)) }
        guard let km = read(k, 0x18) else { break }
        let parent = u64(km, 0x10)
        if !isPtr(parent) || parent == k { break }
        k = parent; depth += 1
    }
    return out
}
func fieldOffset(_ klass: UInt64, _ name: String) -> Int? { fields(klass)[name] }
func pickClass(_ name: String, anchor: String) -> UInt64? {
    for c in classByName[name] ?? [] where fields(c)[anchor] != nil { return c }
    return nil
}
func objClass(_ obj: UInt64) -> (name: String, klass: UInt64)? {
    guard isPtr(obj), let om = read(obj, 0x10), isPtr(u64(om, 0)),
          let vm = read(u64(om, 0), 0x10), isPtr(u64(vm, 0)) else { return nil }
    let kl = u64(vm, 0)
    guard let km = read(kl, 0x48), u64(km, 0x38) == image, let s = cStr(u64(km, 0x40)) else { return nil }
    return (s, kl)
}

func klassName(_ k: UInt64) -> String {
    guard let km = read(k, 0x48) else { return "?" }
    return cStr(u64(km, 0x40), max: 96) ?? "?"
}
func dumpHierarchy(_ klass: UInt64, _ label: String) {
    print("=== \(label) hierarchy (klass \(hex(klass))) ===")
    var k = klass; var depth = 0; var seen = Set<UInt64>()
    while depth < 8 {
        if seen.contains(k) { break }; seen.insert(k)
        let f = fields(k)
        print("[\(depth)] \(klassName(k)) @ \(hex(k)): \(f.count) fields")
        for (n, o) in f.sorted(by: { $0.value < $1.value }) {
            print(String(format: "    +0x%03X %@", o, n))
        }
        guard let km = read(k, 0x18) else { break }
        let parent = u64(km, 0x10)
        if !isPtr(parent) || parent == k { break }
        k = parent; depth += 1
    }
}

// ==== MonoString decode attempts ====
func plausible(_ s: String) -> Bool {
    !s.isEmpty && s.count < 60 && s.allSatisfy { c in
        c.isASCII && (c.isLetter || c.isNumber || "_-#@/. ".contains(c))
    }
}
func tryString(_ addr: UInt64) -> String? {
    guard isPtr(addr) else { return nil }
    guard let m = read(addr, 0x60) else { return nil }
    // A: header 8B, len @8, chars @0x0C
    let la = Int(i32(m, 8))
    if la > 0, la < 60, let ch = read(addr + 0x0C, la * 2),
       let s = String(bytes: ch, encoding: .utf16LittleEndian), plausible(s) { return "A:\(s)" }
    // B: len @0x10, chars @0x14
    let lb = Int(i32(m, 0x10))
    if lb > 0, lb < 60, let ch = read(addr + 0x14, lb * 2),
       let s = String(bytes: ch, encoding: .utf16LittleEndian), plausible(s) { return "B:\(s)" }
    // C: len @8, chars @0x10
    if la > 0, la < 60, let ch = read(addr + 0x10, la * 2),
       let s = String(bytes: ch, encoding: .utf16LittleEndian), plausible(s) { return "C:\(s)" }
    return nil
}
func dumpPointerStrings(_ obj: UInt64, _ label: String, range: Range<Int>) {
    print("=== \(label) pointer-field string scan @ \(hex(obj)) ===")
    guard let m = read(obj, range.upperBound) else { print("read fail"); return }
    for off in stride(from: range.lowerBound, to: range.upperBound, by: 8) {
        let v = u64(m, off)
        guard isPtr(v), !(v >= monoBase && v < monoBase + 0x320000) else { continue }
        if let s = tryString(v) {
            print(String(format: "    +0x%03X → %@", off, s))
        }
    }
}

// ==== locate ZoneMgr → zones ====
guard let zoneMgrClass = pickClass("ZoneMgr", anchor: "m_zones") else { print("no ZoneMgr"); exit(1) }
guard let zoneClass = pickClass("Zone", anchor: "m_cards") else { print("no Zone"); exit(1) }
let cardClasses = classByName["Card"] ?? []
guard let cardClass = cardClasses.first(where: { fields($0)["m_entity"] != nil }) else { print("no Card"); exit(1) }
print("✓ ZoneMgr=\(hex(zoneMgrClass)) Zone=\(hex(zoneClass)) Card=\(hex(cardClass))")

var zmVtable: UInt64 = 0
forEachRegion { base, size in
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(8 * 1024 * 1024, size - offset))
        guard let buf = read(base + offset, n) else { break }
        var hit = false
        buf.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            for k in 0..<n/8 {
                guard k + 2 < n/8 else { break }
                if ptr[k] == zoneMgrClass, ptr[k + 2] == domain { zmVtable = base + offset + UInt64(k*8); hit = true; break }
            }
        }
        if hit { break }
        offset += UInt64(n)
    }
    return zmVtable == 0
}
func staticValue(_ cls: UInt64, _ vt: UInt64, _ field: String) -> UInt64? {
    guard let vm = read(vt, 0x80) else { return nil }
    let flags: UInt8 = vm.withUnsafeBytes { $0.load(fromByteOffset: 0x2F, as: UInt8.self) }
    guard (flags >> 2) & 1 == 1 else { return nil }
    guard let km = read(cls, 0x60) else { return nil }
    let slot = Int(i32(km, 0x54))
    let data = u64(vm, 0x48 + slot * 8)
    guard isPtr(data), let dmm = read(data, 0x200) else { return nil }
    let off = fields(cls)[field] ?? -1
    guard off >= 0, off + 8 <= 0x200 else { return nil }
    return u64(dmm, off)
}

print("等待对局中（己方手牌非空）…")
var friendlyZoneDeck: UInt64 = 0
var friendlyZoneHand: UInt64 = 0
var friendlyPlayer: UInt64 = 0
let zonesOff = fields(zoneMgrClass)["m_zones"]!
let cardsOff = fields(zoneClass)["m_cards"]!
let ctrlOff = fields(zoneClass)["m_controller"]!
guard let playerClass = (classByName["Player"] ?? []).first(where: { fields($0)["m_local"] != nil }) else { print("no Player"); exit(1) }
let localOff = fields(playerClass)["m_local"]!

for attempt in 0..<80 {
    if zmVtable != 0, let zm = staticValue(zoneMgrClass, zmVtable, "s_instance"), isPtr(zm),
       let zmem = read(zm, zonesOff + 8) {
        let zonesList = u64(zmem, zonesOff)
        if isPtr(zonesList), let lm = read(zonesList, 0x20), isPtr(u64(lm, 0x10)) {
            let zsize = Int(Int32(bitPattern: u32(lm, 0x18)))
            let zarr = u64(lm, 0x10)
            if zsize > 0, zsize < 200, let zvec = read(zarr + 0x20, zsize * 8) {
                for e in 0..<zsize {
                    let zone = zvec.withUnsafeBytes { $0.load(fromByteOffset: e * 8, as: UInt64.self) }
                    guard isPtr(zone), let (zname, _) = objClass(zone), let zmm = read(zone, 0x100) else { continue }
                    let ctrl = u64(zmm, ctrlOff)
                    guard isPtr(ctrl), let pm = read(ctrl, localOff + 1) else { continue }
                    let isLocal = pm.withUnsafeBytes { $0.load(fromByteOffset: localOff, as: UInt8.self) } != 0
                    guard isLocal else { continue }
                    if zname == "ZoneDeck" { friendlyZoneDeck = zone }
                    if zname == "ZoneHand" { friendlyZoneHand = zone }
                    friendlyPlayer = ctrl
                }
                // need hand non-empty to calibrate with a card
                if friendlyZoneHand != 0 {
                    let clist = u64(read(friendlyZoneHand, 0x100)!, cardsOff)
                    if isPtr(clist), let clm = read(clist, 0x20), isPtr(u64(clm, 0x10)) {
                        let cs = Int(Int32(bitPattern: u32(clm, 0x18)))
                        if cs > 0 { break }
                    }
                }
            }
        }
    }
    if attempt % 10 == 0 { print("  等待第 \(attempt) 次…") }
    Thread.sleep(forTimeInterval: 3)
}
guard friendlyZoneHand != 0, friendlyZoneDeck != 0 else { print("超时"); exit(1) }
print("✓ 己方 ZoneHand=\(hex(friendlyZoneHand)) ZoneDeck=\(hex(friendlyZoneDeck)) Player=\(hex(friendlyPlayer))")

// ==== calibrate MonoString with Player.m_name ====
if let nameOff = fields(playerClass)["m_name"], let pm = read(friendlyPlayer, nameOff + 8) {
    let np = u64(pm, nameOff)
    if isPtr(np) {
        print("=== Player.m_name @ +0x\(String(nameOff, radix: 16)) ptr=\(hex(np)) raw ===")
        print("    \(hexDump(np, len: 72))")
        print("    tryString: \(tryString(np) ?? "nil")")
    }
}

// ==== dump hierarchies ====
dumpHierarchy(cardClass, "Card")

// first hand card
guard let hm = read(friendlyZoneHand, 0x100) else { exit(1) }
let hlist = u64(hm, cardsOff)
guard let hlm = read(hlist, 0x20), isPtr(u64(hlm, 0x10)) else { print("hand list fail"); exit(1) }
let hsize = Int(Int32(bitPattern: u32(hlm, 0x18)))
let harr = u64(hlm, 0x10)
guard hsize > 0, let hvec = read(harr + 0x20, hsize * 8) else { print("hand empty"); exit(1) }
let firstCard = hvec.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
print("✓ first hand card @ \(hex(firstCard)) (\(objClass(firstCard)?.name ?? "?"))")
print("=== first Card raw (0x80) ===")
print("    \(hexDump(firstCard, len: 0x80))")

let entOff = fields(cardClass)["m_entity"]!
guard let cm = read(firstCard, entOff + 8) else { exit(1) }
let entity = u64(cm, entOff)
print("✓ Card.m_entity @ +0x\(String(entOff, radix: 16)) → \(hex(entity)) (\(objClass(entity)?.name ?? "?"))")
dumpPointerStrings(firstCard, "Card", range: 0..<0x100)
if isPtr(entity) {
    dumpHierarchy(objClass(entity)?.klass ?? 0, "Entity(play)")
    dumpPointerStrings(entity, "Entity(play)", range: 0..<0x120)
    // follow m_staticEntityDef / m_cardDef if present
    if let cls = objClass(entity)?.klass {
        for fld in ["m_staticEntityDef", "m_dynamicEntityDef"] {
            if let o = fieldOffset(cls, fld), let em = read(entity, o + 8) {
                let def = u64(em, o)
                if isPtr(def) {
                    print("✓ Entity.\(fld) → \(hex(def)) (\(objClass(def)?.name ?? "?"))")
                    dumpPointerStrings(def, "\(fld)", range: 0..<0x120)
                    if let dcls = objClass(def)?.klass, fields(dcls)["m_cardId"] == nil {
                        dumpHierarchy(dcls, fld + "-class")
                    }
                }
            }
        }
    }
}
if let cdOff = fields(cardClass)["m_cardDef"], let cm2 = read(firstCard, cdOff + 8) {
    let cardDef = u64(cm2, cdOff)
    if isPtr(cardDef) {
        print("✓ Card.m_cardDef → \(hex(cardDef)) (\(objClass(cardDef)?.name ?? "?"))")
        dumpPointerStrings(cardDef, "CardDef", range: 0..<0x120)
    }
}
print("完成")
