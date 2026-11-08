import Foundation
import AppKit
import Darwin

// 阶段八：GameState 的 MonoVTable → 静态存储 → 游戏单例
// 路线：domain 里找 class_vtable_map（MonoGHashTable，key=MonoClass*）→ GameState 的 vtable
//       → vtable data（静态存储）→ 扫描其中 class 回指 GameState 的对象 = 单例实例

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
func u64(_ d: Data, _ off: Int) -> UInt64 { d.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) } }

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
let monoHi = mono + 0x320000

// GameState MonoClass（堆扫描同 stage7；本会话已定位则直接复用上次值，失败则重扫）
var gameStateClass: UInt64 = 0
// 快路径：扫 domain 附近已知区域代价高，先重用 stage7 方法扫一次 1GB 窗口
do {
    var address: UInt64 = 0x1000
    var done = false
    while !done {
        var size: mach_vm_size_t = 0
        var infoAddr = mach_vm_address_t(address)
        var basic = vm_region_basic_info_data_64_t()
        var infoCnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
        var objectName: mach_port_t = 0
        let kr = withUnsafeMutablePointer(to: &basic) { ptr in
            mach_vm_region(task, &infoAddr, &size, vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
                UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCnt, &objectName)
        }
        guard kr == KERN_SUCCESS else { break }
        defer { address = UInt64(infoAddr) + size }
        guard basic.protection & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }
        var offset: UInt64 = 0
        while offset < size {
            let n = Int(min(8 * 1024 * 1024, size - offset))
            guard let buf = read(UInt64(infoAddr) + offset, n) else { break }
            buf.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
                let words = n / 8
                for k in 0..<words {
                    guard k + 7 < words, base[k + 7] == image else { continue }
                    let p = UInt64(infoAddr) + offset + UInt64(k * 8)
                    let np = base[k + 8]
                    guard isPtr(np), let s = cStr(np), s == "GameState" else { continue }
                    gameStateClass = p
                    done = true
                }
            }
            if done { break }
            offset += UInt64(n)
        }
    }
}
guard gameStateClass != 0 else { print("未找到 GameState MonoClass"); exit(1) }
print("✓ GameState MonoClass @ \(String(gameStateClass, radix: 16))")

// ==== domain 里找 MonoGHashTable（class_vtable_map 候选）====
var ghts: [UInt64] = []
for off in stride(from: 0, to: 0x2000, by: 8) {
    let p = dm.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPtr(p), !(p >= mono && p < monoHi) else { continue }
    guard let t = read(p, 24) else { continue }
    let f1 = u64(t, 0), f2 = u64(t, 8)
    guard f1 >= mono, f1 < monoHi, f2 >= mono, f2 < monoHi else { continue }
    guard isPtr(u64(t, 16)) else { continue }
    ghts.append(p)
}
print("✓ domain 内 MonoGHashTable 候选 \(ghts.count) 个")

// 每个 GHashTable：桶区域扫描 HashEntry {hash, key, value, next}，找 key==GameState
var vtable: UInt64 = 0
for ht in ghts {
    guard let tm = read(ht, 32) else { continue }
    let buckets = u64(tm, 16)
    guard isPtr(buckets) else { continue }
    guard let scan = read(buckets, 256 * 1024) else { continue }
    for o in stride(from: 0, to: scan.count - 8, by: 8) {
        let key = scan.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) }
        guard key == gameStateClass else { continue }
        // HashEntry 布局 {hash, key, value, next}：key 在词1，value 在词2（桶数组元素=entry*）
        // 桶数组元素本身指向 entry；若 key 直接是桶元素值，entry = 该元素地址
        // 桶元素=key 的情形：读元素地址为 entry；也可能桶元素是 entry 指针——两种都试
        // 情形A：桶元素本身就是 entry 指针，hash 在其词0
        let entryAddr = buckets + UInt64(o)
        if let em = read(entryAddr, 32) {
            let v = u64(em, 16)
            if isPtr(v) { vtable = v; break }
        }
        // 情形B：扫描窗口里 key 出现在 entry 的词1 → entry = 地址-8
        let entryAddr2 = buckets + UInt64(o) - 8
        if let em = read(entryAddr2, 32) {
            let k = u64(em, 8)
            if k == gameStateClass {
                let v = u64(em, 16)
                if isPtr(v) { vtable = v }
            }
        }
    }
    if vtable != 0 {
        print("✓ class_vtable_map 候选 @ \(String(ht, radix: 16)) → vtable @ \(String(vtable, radix: 16))")
        break
    }
}
if vtable == 0 { print("GHashTable 路线未中，转堆扫描 MonoVTable…") }

// 兜底：堆扫描 MonoVTable（签名 [w+0x10] == GameState 类指针）
if vtable == 0 {
    var address: UInt64 = 0x1000
    scan: while true {
        var size: mach_vm_size_t = 0
        var infoAddr = mach_vm_address_t(address)
        var basic = vm_region_basic_info_data_64_t()
        var infoCnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
        var objectName: mach_port_t = 0
        let kr = withUnsafeMutablePointer(to: &basic) { ptr in
            mach_vm_region(task, &infoAddr, &size, vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
                UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCnt, &objectName)
        }
        guard kr == KERN_SUCCESS else { break }
        defer { address = UInt64(infoAddr) + size }
        guard basic.protection & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }
        var offset: UInt64 = 0
        while offset < size {
            let n = Int(min(8 * 1024 * 1024, size - offset))
            guard let buf = read(UInt64(infoAddr) + offset, n) else { break }
            var hit = false
            buf.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
                let words = n / 8
                for k in 0..<words {
                    guard k + 2 < words, base[k + 2] == gameStateClass else { continue }
                    let w = UInt64(infoAddr) + offset + UInt64(k * 8)
                    // MonoVTable: +0 = MonoObject.vtable, +8 sync, +10 klass, +18 domain
                    guard isPtr(base[k]), base[k + 3] == domain else { continue }
                    vtable = w
                    hit = true
                }
            }
            if hit { break scan }
            offset += UInt64(n)
        }
    }
    if vtable != 0 { print("✓ 堆扫描 → vtable @ \(String(vtable, radix: 16))") }
}
guard vtable != 0 else { print("未找到 GameState vtable"); exit(1) }

// ==== dump MonoVTable，找静态存储 data ====
guard let vm = read(vtable, 0x80) else { exit(1) }
print("\n=== MonoVTable dump ===")
for w in stride(from: 0, to: 0x80, by: 8) {
    let v = u64(vm, w)
    guard v != 0 else { continue }
    var d = String(v, radix: 16)
    if v == gameStateClass { d = "GameState类指针!!" }
    else if v == domain { d = "domain!" }
    else if isPtr(v) { d = String(v, radix: 16) }
    else { d = "\(v)" }
    print(String(format: "+%02X %@", w, d))
}

// ==== 静态存储扫描：data 指针候选区找 GameState 实例 ====
// MonoVTable.data 偏移未知 → 对 vtable 里每个堆指针，读 0x100，找 [q]==某vtable 且 [vtable+0x10]==GameState 的对象
print("\n=== 静态存储探测 ===")
for w in stride(from: 0x20, to: 0x80, by: 8) {
    let q = u64(vm, w)
    guard isPtr(q), q != gameStateClass, !(q >= mono && q < monoHi) else { continue }
    guard let qm = read(q, 0x200) else { continue }
    var hits: [String] = []
    for o in stride(from: 0, to: 0x200, by: 8) {
        let obj = u64(qm, o)
        guard isPtr(obj) else { continue }
        guard let om = read(obj, 0x18) else { continue }
        let vt = u64(om, 0)
        guard isPtr(vt) else { continue }
        guard let vm2 = read(vt, 0x18) else { continue }
        let kl = u64(vm2, 0x10)
        if kl == gameStateClass { hits.append("+\(String(o, radix: 16)) → GameState 实例 @ \(String(obj, radix: 16))") }
    }
    if !hits.isEmpty {
        print("data 候选 @ +0x\(String(w, radix: 16))（\(String(q, radix: 16))）:")
        for hh in hits { print("   \(hh)") }
    }
}
print("\n完成")
