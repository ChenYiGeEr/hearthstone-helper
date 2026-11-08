import Foundation
import AppKit
import Darwin

// 阶段一探针：附着游戏进程 → 定位 mono dylib → 读 mono_get_root_domain → 根域指针
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
}
guard let app = apps.first else { print("炉石未运行"); exit(1) }
print("炉石 PID: \(app.processIdentifier)")

var task: mach_port_t = 0
let tr = task_for_pid(mach_task_self_, app.processIdentifier, &task)
guard tr == KERN_SUCCESS else { print("task_for_pid 失败: \(tr)"); exit(1) }
print("✓ 已附着远程任务端口 \(task)")

var info = task_dyld_info_data_t()
var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<natural_t>.size)
let ti = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(17), $0, &count)
    }
}
guard ti == KERN_SUCCESS else { print("task_info 失败: \(ti)"); exit(1) }
let dyldAddr = info.all_image_info_addr

func read(_ addr: UInt64, _ size: Int) -> Data? {
    var dataPtr: vm_offset_t = 0
    var dataCount: mach_msg_type_number_t = 0
    let kr = vm_read(task, vm_address_t(addr), vm_size_t(size), &dataPtr, &dataCount)
    guard kr == KERN_SUCCESS else { return nil }
    defer { vm_deallocate(mach_task_self_, dataPtr, vm_size_t(dataCount)) }
    return Data(bytes: UnsafeRawPointer(bitPattern: dataPtr)!, count: Int(dataCount))
}

guard let header = read(dyldAddr, 16) else { print("读 dyld 头失败"); exit(1) }
let imageCount = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
let infoArray = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
print("✓ 远程已加载镜像数 \(imageCount)")

guard let arrayData = read(infoArray, imageCount * 24) else { print("读镜像表失败"); exit(1) }

var monoLoadAddr: UInt64?
for i in 0..<imageCount {
    let off = i * 24
    let loadAddr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
    let filePathPtr = arrayData.withUnsafeBytes { $0.load(fromByteOffset: off + 8, as: UInt64.self) }
    guard let pathData = read(filePathPtr, 512) else { continue }
    let path = String(bytes: pathData.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    if path.contains("libmonobdwgc") {
        monoLoadAddr = loadAddr
        print("✓ 找到 mono dylib: \(path)")
        print("  加载地址 \(String(loadAddr, radix: 16))")
        break
    }
}
guard let loadAddr = monoLoadAddr else { print("未找到 mono dylib"); exit(1) }

// _mono_get_root_domain n_value = 0x11853c，__TEXT vmaddr = 0 → 远程地址 = loadAddr + 0x11853c
let exportAddr = loadAddr + 0x11853c
guard let exportData = read(exportAddr, 8) else { print("读导出指令失败"); exit(1) }
let insn1 = exportData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) } // ADRP X8
let insn2 = exportData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) } // LDR X0, [X8, #imm]

// ADRP 解码: immlo = bits30-29, immhi = bits23-5
let immlo = (insn1 >> 29) & 0x3
let immhi = (insn1 >> 5) & 0x7FFFF
var imm = Int((immhi << 2) | immlo)
if imm & (1 << 20) != 0 { imm -= (1 << 21) } // 符号扩展 21 位
let adrpTarget = (exportAddr & ~UInt64(0xFFF)) + UInt64(imm * 4096)

// LDR X0, [X8, #imm12]: 64 位时 scale=8
let ldrOffset = ((insn2 >> 10) & 0xFFF) * 8
let rootDomainPtrAddr = adrpTarget + UInt64(ldrOffset)

guard let rootData = read(rootDomainPtrAddr, 8) else { print("读根域指针失败"); exit(1) }
let rootDomain = rootData.withUnsafeBytes { $0.load(as: UInt64.self) }

print("✓ 里程碑 A 完整达成：")
print("  _mono_get_root_domain @ \(String(exportAddr, radix: 16))")
print("  ADRP 目标页 \(String(adrpTarget, radix: 16)) + LDR 偏移 \(String(ldrOffset, radix: 16))")
print("  根域指针槽 \(String(rootDomainPtrAddr, radix: 16))")
print("  MonoDomain* = \(String(rootDomain, radix: 16)) \(rootDomain != 0 ? "✓ 非空，根域存活" : "✗ 为空")")
