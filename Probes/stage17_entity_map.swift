import Foundation
import AppKit
import Darwin

// 阶段十七：GameState.m_entityMap 枚举 —— 牌库内容是否有内存路径
// (a) 读 m_entityMap（Dictionary<int, Entity>），dump 条目：cardID / zone / class
// (b) 牌库卡[0] 的 m_staticEntityDef 深扫（次级路径）

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
    var out: [String] = []
    for row in stride(from: 0, to: len, by: 32) {
        var line = String(format: "+0x%03X", row)
        for k in 0..<4 {
            let v = d.withUnsafeBytes { $0.load(fromByteOffset: row + k*8, as: UInt64.self) }
            line += String(format: " %016llx", v)
        }
        out.append(line)
    }
    return out.joined(separator: "\n")
}

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
guard monoBase != 0 else { exit(1) }
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

let wantClasses = Set(["ZoneMgr", "Zone", "Card", "Player", "GameState"])
var classByName: [String: [UInt64]] = [:]
forEachRegion { base, size in
    var offset: UInt64 = 0
    while offset < size {
        let n = Int(min(8 * 1024 * 1024, size - offset))
        guard let buf = read(base + offset, n) else { break }
        buf.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            for k in 0..<n/8 {
                guard k + 8 < n/8 else { break }
                if ptr[k + 7] == image {
                    let addr = base + offset + UInt64(k * 8)
                    let np = ptr[k + 8]
                    if isPtr(np), let s = cStr(np), wantClasses.contains(s) { classByName[s, default: []].append(addr) }
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

guard let gameStateClass = pickClass("GameState", anchor: "s_instance"),
      let zoneMgrClass = pickClass("ZoneMgr", anchor: "m_zones") else { print("类锚点失败"); exit(1) }
print("✓ GameState fields: m_entityMap offset = \(fields(gameStateClass)["m_entityMap"].map { "+0x" + String($0, radix: 16) } ?? "无")")

// vtables
func findVtable(_ klass: UInt64) -> UInt64 {
    var vt: UInt64 = 0
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
                    if ptr[k] == klass, ptr[k + 2] == domain { vt = base + offset + UInt64(k*8); hit = true; break }
                }
            }
            if hit { break }
            offset += UInt64(n)
        }
        return vt == 0
    }
    return vt
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

let gsVt = findVtable(gameStateClass)
let zmVt = findVtable(zoneMgrClass)
guard gsVt != 0, zmVt != 0 else { print("vtable 失败"); exit(1) }

// wait for match
var gs: UInt64 = 0
for _ in 0..<100 {
    if let v = staticValue(gameStateClass, gsVt, "s_instance"), isPtr(v) { gs = v; break }
    Thread.sleep(forTimeInterval: 3)
}
guard gs != 0 else { print("超时（不在对局）"); exit(1) }
print("✓ GameState.s_instance @ \(hex(gs))")

// ===== (a) m_entityMap =====
guard let emOff = fields(gameStateClass)["m_entityMap"] else { print("无 m_entityMap 字段"); exit(1) }
guard let gm = read(gs, emOff + 8) else { exit(1) }
let mapPtr = u64(gm, emOff)
print("m_entityMap ptr = \(hex(mapPtr))")
if isPtr(mapPtr) {
    print("map object raw:")
    print(hexDump(mapPtr, len: 64))

    func tryDict(_ d: UInt64, _ label: String) -> [(Int, UInt64)]? {
        guard let m = read(d, 0x30) else { return nil }
        let entries = u64(m, 0x18)
        let count = Int(i32(m, 0x20))
        guard isPtr(entries), count > 0, count < 20000 else { return nil }
        guard let am = read(entries, 0x28) else { return nil }
        let alen = Int(i32(am, 0x18))
        guard alen >= count, alen < 20000 else { return nil }
        let vec = u64(am, 0x20)
        guard isPtr(vec) else { return nil }
        let stride = 24
        guard let buf = read(vec, min(count, 1000) * stride) else { return nil }
        var out: [(Int, UInt64)] = []
        for i in 0..<min(count, 1000) {
            let key = Int(i32(buf, i*stride + 8))
            let val = u64(buf, i*stride + 16)
            if isPtr(val) { out.append((key, val)) }
        }
        print("  [\(label)] count=\(count) entries=\(hex(entries)) → 解析出 \(out.count) 个非空值")
        return out
    }

    var entries: [(Int, UInt64)]? = tryDict(mapPtr, "dict@+0")
    if entries == nil {
        if let wm = read(mapPtr, 0x20) {
            for o in stride(from: 0, to: 0x20, by: 8) {
                let p = u64(wm, o)
                if isPtr(p), let e = tryDict(p, "dict@+0x\(String(o, radix: 16))") { entries = e; break }
            }
        }
    }

    if let entries {
        print("=== 头 30 个实体 ===")
        for (id, ent) in entries.prefix(30) {
            var cardID = "?"
            if let em = read(ent, 0x30) {
                let sp = u64(em, 0x28)
                if isPtr(sp), let sm = read(sp, 0x40) {
                    let len = Int(i32(sm, 0x10))
                    if len > 0, len < 64, let ch = read(sp + 0x14, len * 2),
                       let s = String(bytes: ch, encoding: .utf16LittleEndian), !s.isEmpty {
                        cardID = s
                    }
                }
            }
            var zone = -1
            if let em = read(ent, 0xC0) { zone = Int(i32(em, 0xB8)) }
            let cls = objClassName(ent) ?? "?"
            print("  id=\(id) cls=\(cls) cardID=\(cardID) zone=\(zone)")
        }
        // zone 分布统计
        var zoneHist: [Int: Int] = [:]
        var withCardID = 0
        for (_, ent) in entries {
            if let em = read(ent, 0xC0) {
                let z = Int(i32(em, 0xB8))
                zoneHist[z, default: 0] += 1
            }
            if let em = read(ent, 0x30) {
                let sp = u64(em, 0x28)
                if isPtr(sp), let sm = read(sp, 0x40), Int(i32(sm, 0x10)) > 0 { withCardID += 1 }
            }
        }
        print("zone 分布: \(zoneHist.sorted { $0.key < $1.key })  有 cardID 的: \(withCardID)/\(entries.count)")
    } else {
        print("字典解析失败")
    }
} else {
    print("m_entityMap 为空")
}

// ===== (b) 牌库卡[0] 实体 def 深扫 =====
let zonesOff = fields(zoneMgrClass)["m_zones"]!
guard let zm2 = staticValue(zoneMgrClass, zmVt, "s_instance"), isPtr(zm2),
      let zmm = read(zm2, zonesOff + 8) else { exit(0) }
let zonesList = u64(zmm, zonesOff)
guard isPtr(zonesList), let lm = read(zonesList, 0x20), isPtr(u64(lm, 0x10)) else { exit(0) }
let zsize = Int(Int32(bitPattern: u32(lm, 0x18)))
guard zsize > 0, zsize < 200, let zvec = read(u64(lm, 0x10) + 0x20, zsize * 8) else { exit(0) }
guard let zoneClass = pickClass("Zone", anchor: "m_cards"),
      let cardClass = pickClass("Card", anchor: "m_entity"),
      let playerClass = pickClass("Player", anchor: "m_local") else { exit(0) }
let cardsOff = fields(zoneClass)["m_cards"]!
let ctrlOff = fields(zoneClass)["m_controller"]!
let localOff = fields(playerClass)["m_local"]!
let entOff = fields(cardClass)["m_entity"]!

var deckZone: UInt64 = 0
for e in 0..<zsize {
    let zone = zvec.withUnsafeBytes { $0.load(fromByteOffset: e * 8, as: UInt64.self) }
    guard isPtr(zone), objClassName(zone) == "ZoneDeck", let zzm = read(zone, 0x100) else { continue }
    let ctrl = u64(zzm, ctrlOff)
    guard isPtr(ctrl), let pm = read(ctrl, localOff + 1) else { continue }
    if pm.withUnsafeBytes { $0.load(fromByteOffset: localOff, as: UInt8.self) } != 0 { deckZone = zone }
}
if deckZone != 0, let zz = read(deckZone, cardsOff + 8) {
    let clist = u64(zz, cardsOff)
    if isPtr(clist), let clm = read(clist, 0x20), isPtr(u64(clm, 0x10)) {
        let cs = Int(Int32(bitPattern: u32(clm, 0x18)))
        if cs > 0, let cvec = read(u64(clm, 0x10) + 0x20, cs * 8) {
            let card = cvec.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
            if isPtr(card), let cm = read(card, entOff + 8) {
                let entity = u64(cm, entOff)
                if isPtr(entity), let em = read(entity, 0x48) {
                    print("=== 牌库卡[0] entity.m_staticEntityDef(+0x38) = \(hex(u64(em, 0x38))) ===")
                    let def = u64(em, 0x38)
                    if isPtr(def), let dmm = read(def, 0x100) {
                        // 深扫字符串 0..0x100
                        for o in stride(from: 0, to: 0x100, by: 8) {
                            let v = u64(dmm, o)
                            guard isPtr(v), !(v >= monoBase && v < monoBase + 0x320000) else { continue }
                            if let sm = read(v, 0x40) {
                                let len = Int(i32(sm, 0x10))
                                if len > 0, len < 64, let ch = read(v + 0x14, len * 2),
                                   let s = String(bytes: ch, encoding: .utf16LittleEndian), !s.isEmpty {
                                    print("  def+0x\(String(o, radix: 16)) → '\(s)'")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
print("完成")
