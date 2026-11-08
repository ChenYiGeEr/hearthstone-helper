import Foundation
import AppKit
import Darwin

// 阶段二 b（诊断增强版）：三种容器解释 × 更大范围
import Darwin
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { print("炉石未运行"); exit(1) }

var task: mach_port_t = 0
let handle = dlopen("HearthMirror.framework/HearthMirror", RTLD_NOW) ?? dlopen(nil, RTLD_NOW)
if let handle, let sym = dlsym(handle, "acquireTaskportRight") {
    let fn = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    _ = fn()
}
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else {
    print("task_for_pid 失败"); exit(1)
}

func read(_ addr: UInt64, _ size: Int) -> Data? {
    var dataPtr: vm_offset_t = 0
    var dataCount: mach_msg_type_number_t = 0
    let kr = vm_read(task, vm_address_t(addr), vm_size_t(size), &dataPtr, &dataCount)
    guard kr == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, dataPtr, vm_size_t(dataCount)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: dataPtr)!, count: Int(dataCount))
}
func cString(at addr: UInt64, max: Int = 200) -> String? {
    guard let d = read(addr, max) else { return nil }
    let bytes = d.prefix { $0 != 0 }
    guard bytes.count >= 4 else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}
func isPlausiblePtr(_ p: UInt64) -> Bool { p > 0x1000_0000 && p < 0x8000_0000_0000 }

var info = task_dyld_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size)
_ = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(17), $0, &count)
    }
}
let dyldAddr = info.all_image_info_addr
guard let header = read(dyldAddr, 16) else { exit(1) }
let imageCount = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let infoArray = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
guard let arrayData = read(infoArray, imageCount * 24) else { exit(1) }
var monoLoadAddr: UInt64?
for i in 0..<imageCount {
    let off = i * 24
    let loadAddr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    let fp = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt64.self) }
    guard let pd = read(fp, 512) else { continue }
    if (String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? "").contains("libmonobdwgc") { monoLoadAddr = loadAddr; break }
}
guard let loadAddr = monoLoadAddr else { exit(1) }
let exportAddr = loadAddr + 0x11853c
guard let ins = read(exportAddr, 8) else { exit(1) }
let i1 = ins.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
let i2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
let immlo = (i1 >> 29) & 0x3
let immhi = (i1 >> 5) & 0x7FFFF
var imm = Int((immhi << 2) | immlo)
if imm & (1 << 20) != 0 { imm -= (1 << 21) }
let domain = read((exportAddr & ~UInt64(0xFFF)) + UInt64(imm * 4096) + UInt64(((i2 >> 10) & 0xFFF) * 8), 8)!
    .withUnsafeBytes { $0.load(as: UInt64.self) }
print("MonoDomain* = \(String(domain, radix: 16))")

// MonoAssembly 候选：assembly → (偏移未知处) MonoImage* → image 内 ".dll" 名字
func assemblyDllName(_ assembly: UInt64) -> [(String, Int, UInt64)] {
    guard let amem = read(assembly, 0x100) else { return [] }
    var out: [(String, Int, UInt64)] = []
    // 在 assembly 对象内找 MonoImage* 候选
    for off in stride(from: 0, to: 0x100, by: 8) {
        let image = amem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
        guard isPlausiblePtr(image), let imem = read(image, 0x200) else { continue }
        // image 内找 ".dll" 字符串指针（MonoImage.name）
        for ioff in stride(from: 0, to: 0x200, by: 8) {
            let np = imem.withUnsafeBytes { $0.load(fromByteOffset: ioff, as: UInt64.self) }
            guard isPlausiblePtr(np), let s = cString(at: np, max: 64), s.hasSuffix(".dll") else { continue }
            out.append((s, off, image))
            break
        }
    }
    return out
}

// 三种容器解释
func walkGSList(_ head: UInt64) -> [UInt64] {
    var items: [UInt64] = []
    var node = head
    for _ in 0..<200 {
        guard isPlausiblePtr(node), let d = read(node, 16) else { break }
        let data = d.withUnsafeBytes { $0.load(as: UInt64.self) }
        let next = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        guard isPlausiblePtr(data) else { break }
        items.append(data)
        if next == 0 || next == node { break }
        node = next
    }
    return items
}
func walkGList(_ head: UInt64) -> [UInt64] {
    var items: [UInt64] = []
    var node = head
    for _ in 0..<200 {
        guard isPlausiblePtr(node), let d = read(node, 24) else { break }
        let data = d.withUnsafeBytes { $0.load(as: UInt64.self) }
        let next = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        guard isPlausiblePtr(data) else { break }
        items.append(data)
        if next == 0 || next == node { break }
        node = next
    }
    return items
}
func readGPtrArray(_ head: UInt64) -> [UInt64] {
    guard let d = read(head, 16) else { return [] }
    let pdata = d.withUnsafeBytes { $0.load(as: UInt64.self) }
    let len = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
    guard isPlausiblePtr(pdata), len > 0, len < 1000 else { return [] }
    guard let arr = read(pdata, Int(len) * 8) else { return [] }
    return (0..<Int(len)).compactMap { i in
        let p = arr.withUnsafeBytes { $0.load(fromByteOffset: i * 8, as: UInt64.self) }
        return isPlausiblePtr(p) ? p : nil
    }
}

guard let domainMem = read(domain, 0x2000) else { exit(1) }
print("=== 域字段扫描（+0x00..0x2000）：能识别 ≥5 个 .dll 的容器 ===")
for off in stride(from: 0x00, to: 0x2000, by: 8) {
    let p = domainMem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard isPlausiblePtr(p) else { continue }
    for (kind, items) in [("GSList", walkGSList(p)), ("GList", walkGList(p)), ("GPtrArray", readGPtrArray(p))] {
        guard items.count >= 5 else { continue }
        var dllCount = 0
        var names: [String] = []
        for item in items.prefix(40) {
            let found = assemblyDllName(item)
            if !found.isEmpty {
                dllCount += 1
                if names.count < 4 { names.append(found[0].0) }
            }
        }
        if dllCount >= 5 {
            print(String(format: "+0x%03X [%@] %d 项, %d 个 MonoAssembly", off, kind, items.count, dllCount))
            print("      \(names.joined(separator: ", "))")
            if off == 0xB0 {
                print("=== 全部程序集 ===")
                for item in items {
                    let found = assemblyDllName(item)
                    if let first = found.first {
                        print("  \(first.0) @ assembly+0x\(String(first.1, radix: 16)) image=\(String(first.2, radix: 16))")
                    }
                }
            }
        }
    }
}
print("扫描完成")
