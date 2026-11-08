import Foundation
import AppKit
import Darwin

// 阶段十六：读己方 ZoneDeck / ZoneHand 全部 cardID（验证 Card.m_entity → 实体 +0x28 的普适性）
// 复用 stage15 已验证链路；MonoString 布局 B（len @ +0x10, chars @ +0x14）

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

let wantClasses = Set(["ZoneMgr", "Zone", "Card", "Player"])
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

var fieldsCache: [UInt64: [String: Int]] = [:]
func fields(_ klass: UInt64) -> [String: Int] {
    if let f = fieldsCache[klass] { return f }
    var map: [String: Int] = [:]
    if let km = read(klass, 0x98), isPtr(u64(km, 0x90)), let fm = read(u64(km, 0x90), 0x20 * 400) {
        for e in 0..<400 {
            let base = e * 0x20
            let np = u64(fm, base + 8)
            guard isPtr(np), let s = cStr(np, max: 96) else { break }
            map[s] = Int(i32(fm, base + 0x18))
        }
    }
    fieldsCache[klass] = map
    return map
}
func pickClass(_ name: String, anchor: String) -> UInt64? {
    for c in classByName[name] ?? [] where fields(c)[anchor] != nil { return c }
    return nil
}
func objClassName(_ obj: UInt64) -> String? {
    guard isPtr(obj), let om = read(obj, 0x10), isPtr(u64(om, 0)),
          let vm = read(u64(om, 0), 0x10), isPtr(u64(vm, 0)) else { return nil }
    let kl = u64(vm, 0)
    guard let km = read(kl, 0x48), u64(km, 0x38) == image else { return nil }
    return cStr(u64(km, 0x40))
}

guard let zoneMgrClass = pickClass("ZoneMgr", anchor: "m_zones"),
      let zoneClass = pickClass("Zone", anchor: "m_cards"),
      let cardClass = pickClass("Card", anchor: "m_entity"),
      let playerClass = pickClass("Player", anchor: "m_local") else {
    print("锚点验证失败"); exit(1)
}
print("✓ classes ok; Card.m_entity @ +0x\(String(fields(cardClass)["m_entity"]!, radix: 16))")

var zmVtable: UInt64 = 0
func findZoneMgrVtable() {
    guard zmVtable == 0 else { return }
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
                    if ptr[k] == zoneMgrClass, ptr[k + 2] == domain {
                        zmVtable = base + offset + UInt64(k*8); hit = true; break
                    }
                }
            }
            if hit { break }
            offset += UInt64(n)
        }
        return zmVtable == 0
    }
}
findZoneMgrVtable()
guard zmVtable != 0 else { print("无 ZoneMgr vtable"); exit(1) }
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

// MonoString 布局 B（stage15 实证）：len @ +0x10, UTF-16 chars @ +0x14
func monoString(_ addr: UInt64) -> String? {
    guard isPtr(addr), let m = read(addr, 0x40) else { return nil }
    let len = Int(i32(m, 0x10))
    guard len > 0, len < 64 else { return nil }
    guard let ch = read(addr + 0x14, len * 2),
          let s = String(bytes: ch, encoding: .utf16LittleEndian), !s.isEmpty else { return nil }
    return s
}
// Card → m_entity → 实体 +0x28 → MonoString cardID
let entOff = fields(cardClass)["m_entity"]!
func cardID(_ card: UInt64) -> String? {
    guard isPtr(card), let cm = read(card, entOff + 8) else { return nil }
    let entity = u64(cm, entOff)
    guard isPtr(entity), let em = read(entity, 0x30) else { return nil }
    let strPtr = u64(em, 0x28)
    guard isPtr(strPtr) else { return nil }
    guard let s = monoString(strPtr) else { return nil }
    guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
    return s
}

let zonesOff = fields(zoneMgrClass)["m_zones"]!
let cardsOff = fields(zoneClass)["m_cards"]!
let ctrlOff = fields(zoneClass)["m_controller"]!
let localOff = fields(playerClass)["m_local"]!

func readZoneCards(_ zone: UInt64) -> [String] {
    guard let zm = read(zone, cardsOff + 8) else { return [] }
    let clist = u64(zm, cardsOff)
    guard isPtr(clist), let clm = read(clist, 0x20), isPtr(u64(clm, 0x10)) else { return [] }
    let cs = Int(Int32(bitPattern: u32(clm, 0x18)))
    guard cs > 0, cs < 100, let cvec = read(u64(clm, 0x10) + 0x20, cs * 8) else { return [] }
    var ids: [String] = []
    for ci in 0..<cs {
        let card = cvec.withUnsafeBytes { $0.load(fromByteOffset: ci * 8, as: UInt64.self) }
        if let id = cardID(card) { ids.append(id) } else { ids.append("?") }
    }
    return ids
}

print("等待对局中（己方手牌非空）…")
var friendlyZoneDeck: UInt64 = 0
var friendlyZoneHand: UInt64 = 0
for attempt in 0..<100 {
    if let zm = staticValue(zoneMgrClass, zmVtable, "s_instance"), isPtr(zm),
       let zmem = read(zm, zonesOff + 8) {
        let zonesList = u64(zmem, zonesOff)
        if isPtr(zonesList), let lm = read(zonesList, 0x20), isPtr(u64(lm, 0x10)) {
            let zsize = Int(Int32(bitPattern: u32(lm, 0x18)))
            let zarr = u64(lm, 0x10)
            if zsize > 0, zsize < 200, let zvec = read(zarr + 0x20, zsize * 8) {
                friendlyZoneDeck = 0; friendlyZoneHand = 0
                for e in 0..<zsize {
                    let zone = zvec.withUnsafeBytes { $0.load(fromByteOffset: e * 8, as: UInt64.self) }
                    guard isPtr(zone), let zname = objClassName(zone), let zmm = read(zone, 0x100) else { continue }
                    let ctrl = u64(zmm, ctrlOff)
                    guard isPtr(ctrl), let pm = read(ctrl, localOff + 1) else { continue }
                    let isLocal = pm.withUnsafeBytes { $0.load(fromByteOffset: localOff, as: UInt8.self) } != 0
                    guard isLocal else { continue }
                    if zname == "ZoneDeck" { friendlyZoneDeck = zone }
                    if zname == "ZoneHand" { friendlyZoneHand = zone }
                }
                if friendlyZoneHand != 0 {
                    let cards = readZoneCards(friendlyZoneHand)
                    if cards.count > 0, !cards.contains("?") { break }
                }
            }
        }
    }
    if attempt % 10 == 0 { print("  等待第 \(attempt) 次…") }
    Thread.sleep(forTimeInterval: 3)
}
guard friendlyZoneHand != 0, friendlyZoneDeck != 0 else { print("超时"); exit(1) }

let handIDs = readZoneCards(friendlyZoneHand)
let deckIDs = readZoneCards(friendlyZoneDeck)
print("✓ 己方手牌 \(handIDs.count) 张：\(handIDs.joined(separator: " "))")
print("✓ 己方牌库 \(deckIDs.count) 张：\(deckIDs.joined(separator: " "))")
let unknown = (handIDs + deckIDs).filter { $0 == "?" }.count
print("读取失败卡数：\(unknown)")
print("完成（对照游戏画面验证张数与内容）")
