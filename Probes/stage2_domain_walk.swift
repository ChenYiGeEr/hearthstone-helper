import Foundation
import AppKit
import Darwin

// 阶段二探针：MonoDomain 布局锚定
import Darwin
// 目标：dump 根域内存，用 friendly_name 字符串锚定结构布局，
//       找到指向 MonoAssembly 数组的字段。

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { print("炉石未运行"); exit(1) }

var task: mach_port_t = 0
// 直接链接预编译框架里的 acquireTaskportRight（security.h 导出）
let handle = dlopen("HearthMirror.framework/HearthMirror", RTLD_NOW)
    ?? dlopen(nil, RTLD_NOW)
typealias AcquireFn = @convention(c) () -> Int32
if let handle, let sym = dlsym(handle, "acquireTaskportRight") {
    let fn = unsafeBitCast(sym, to: AcquireFn.self)
    _ = fn()
}
guard task_for_pid(mach_task_self_, app.processIdentifier, &task) == KERN_SUCCESS else {
    print("task_for_pid 失败（需要调试权限签名）"); exit(1)
}

var info = task_dyld_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size)
_ = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(17), $0, &count)
    }
}
let dyldAddr = info.all_image_info_addr

func read(_ addr: UInt64, _ size: Int) -> Data? {
    var dataPtr: vm_offset_t = 0
    var dataCount: mach_msg_type_number_t = 0
    let kr = vm_read(task, vm_address_t(addr), vm_size_t(size), &dataPtr, &dataCount)
    guard kr == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, dataPtr, vm_size_t(dataCount)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: dataPtr)!, count: Int(dataCount))
}

guard let header = read(dyldAddr, 16) else { print("读 dyld 失败"); exit(1) }
let imageCount = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let infoArray = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
guard let arrayData = read(infoArray, imageCount * 24) else { exit(1) }

var monoLoadAddr: UInt64?
for i in 0..<imageCount {
    let off = i * 24
    let loadAddr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    let filePathPtr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt64.self) }
    guard let pd = read(filePathPtr, 512) else { continue }
    let path = String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    if path.contains("libmonobdwgc") { monoLoadAddr = loadAddr; break }
}
guard let loadAddr = monoLoadAddr else { print("未找到 mono"); exit(1) }
let exportAddr = loadAddr + 0x11853c
guard let ins = read(exportAddr, 8) else { exit(1) }
let insn1 = ins.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
let insn2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
let immlo = (insn1 >> 29) & 0x3
let immhi = (insn1 >> 5) & 0x7FFFF
var imm = Int((immhi << 2) | immlo)
if imm & (1 << 20) != 0 { imm -= (1 << 21) }
let adrpTarget = (exportAddr & ~UInt64(0xFFF)) + UInt64(imm * 4096)
let rootDomainPtrAddr = adrpTarget + UInt64(((insn2 >> 10) & 0xFFF) * 8)
guard let rd = read(rootDomainPtrAddr, 8) else { exit(1) }
let domain = rd.withUnsafeBytes { $0.load(as: UInt64.self) }
print("MonoDomain* = \(String(domain, radix: 16))")

// ===== 锚定法：dump 域内前 0x800 字节，找指向可读字符串的指针 =====
guard let domainMem = read(domain, 0x800) else { print("读域内存失败"); exit(1) }

func cString(at addr: UInt64, max: Int = 128) -> String? {
    guard let d = read(addr, max) else { return nil }
    let bytes = d.prefix { $0 != 0 }
    guard bytes.count >= 3 else { return nil }
    // 可读 ASCII/UTF8 判定
    guard bytes.allSatisfy({ (32...126).contains($0) || $0 > 127 }) else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}

print("=== 域内存中指向可读字符串的指针（偏移: 字符串）===")
for off in stride(from: 0, to: 0x800, by: 8) {
    let ptr = domainMem.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    guard ptr > 0x1000_0000, ptr < 0x8000_0000_0000 else { continue }
    if let s = cString(at: ptr) {
        print(String(format: "+0x%03X", off), "→", s.prefix(60))
    }
}
