import AppKit
import Foundation
import Observation
import HearthMirror

/// Live in-match zone counts read directly from the Hearthstone process memory
/// (Mono runtime walk). The prebuilt HearthMirror framework has no in-match
/// zone APIs for macOS, so this module implements the probe-verified recipe:
///
///   attach → dyld → libmonobdwgc → root domain → Assembly-CSharp image
///   → heap scan for target MonoClasses → vtables → static field data
///   → GameState.s_instance / ZoneMgr.s_instance → m_zones → per-zone m_cards
///
/// Layouts are empirically pinned (see Probes/README.md) and stable across
/// game restarts — only runtime addresses change. Setup (the heap scan) runs
/// once per game session on a background task; polls are cheap pointer walks.
@MainActor
@Observable
final class MirrorMemoryStore {
    struct ZoneCounts: Equatable {
        var friendlyHand: Int?
        var opponentHand: Int?
        var friendlyDeck: Int?
        var opponentDeck: Int?
        var friendlyBoard: Int?
        var opponentBoard: Int?
    }

    private(set) var inMatch = false
    private(set) var counts: ZoneCounts?
    /// 己方手牌 cardID 列表，直接读 ZoneHand.m_cards（内存为准）。
    /// T5 日志在重发牌时会让手牌滞后，内存读到的这张列表才是真手牌。
    private(set) var friendlyHandCardIDs: [String]?
    /// Diagnostic stage for the dashboard badge: 未附着 / 扫描中 / 就绪 / 失败原因
    private(set) var stage: String = "未附着"

    private var pollTask: Task<Void, Never>?
    private var setupPID: pid_t = 0
    private var lastStateLine = ""
    private var lastPollLine = ""
    private var lastHandLine = ""
    /// Engine state lives off-main; guarded by the serial engine queue.
    private let engine = MirrorMemoryEngine()

    /// Guards against duplicate poll loops: SwiftUI may evaluate the @State
    /// initial expression several times during launch, creating throwaway
    /// MatchStore instances whose init() calls start().
    @MainActor private static var pollLoopStarted = false

    func start() {
        guard pollTask == nil, !Self.pollLoopStarted else { return }
        Self.pollLoopStarted = true
        pollTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/memory_debug.log")
        func logDebug(_ msg: String) {
            let line = "\(Date.now.formatted(.dateTime.hour().minute().second())) \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
        
        while !Task.isCancelled {
            let app = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
            }
            guard let app else {
                await MainActor.run {
                    stage = "未附着"
                    inMatch = false
                    counts = nil
                }
                engine.reset()
                setupPID = 0
                friendlyHandCardIDs = nil
                logDebug("No Hearthstone app, reset")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            let stateLine = "App found pid=\(app.processIdentifier), setupPID=\(setupPID), stage=\(stage)"
            if lastStateLine != stateLine {
                lastStateLine = stateLine
                logDebug(stateLine)
            }
            if setupPID != app.processIdentifier {
                await MainActor.run { stage = "扫描中…" }
                let ok = await engine.setup(pid: app.processIdentifier)
                setupPID = ok ? app.processIdentifier : 0
                await MainActor.run {
                    stage = ok ? "就绪" : "扫描失败（下轮重试）"
                }
                logDebug("Setup \(ok ? "ok" : "failed"), stage=\(stage)")
                if !ok {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
            }
            let snapshot = await engine.poll()
            await MainActor.run {
                inMatch = snapshot.inMatch
                counts = snapshot.counts
                friendlyHandCardIDs = snapshot.handCardIDs
            }
            let pollLine = "Poll: inMatch=\(snapshot.inMatch), counts=\(snapshot.counts != nil ? "present" : "nil")"
            if lastPollLine != pollLine {
                lastPollLine = pollLine
                logDebug(pollLine)
            }
            let handLine = "Hand IDs (\(snapshot.handCardIDs?.count ?? -1)): \(snapshot.handCardIDs?.sorted().joined(separator: ",") ?? "nil")"
            if lastHandLine != handLine {
                lastHandLine = handLine
                logDebug(handLine)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

// MARK: - Engine (off-main memory reading)

/// All remote-memory work happens here, off the main actor.
private final class MirrorMemoryEngine: @unchecked Sendable {
    private var task: mach_port_t = 0
    private var monoBase: UInt64 = 0
    private var domain: UInt64 = 0
    private var image: UInt64 = 0

    // Resolved per session
    private var classByName: [String: UInt64] = [:]
    private var vtByClass: [String: UInt64] = [:]
    private var fieldsCache: [UInt64: [String: Int]] = [:]
    private var zoneKindCache: [UInt64: String] = [:]  // vtable ptr → zone class name
    private var lastPollSummary = ""  // throttles the OK log to change-only

    struct Snapshot {
        var inMatch = false
        var counts: MirrorMemoryStore.ZoneCounts?
        /// Friendly hand cardIDs read from ZoneHand.m_cards; nil when the
        /// hand list could not be read (callers fall back to log data).
        var handCardIDs: [String]?
    }

    func reset() {
        task = 0
        classByName = [:]
        vtByClass = [:]
        fieldsCache = [:]
        zoneKindCache = [:]
    }

    // MARK: remote primitives

    private func read(_ addr: UInt64, _ size: Int) -> Data? {
        guard task != 0 else { return nil }
        var p: vm_offset_t = 0
        var c: mach_msg_type_number_t = 0
        guard vm_read(task, vm_address_t(addr), vm_size_t(size), &p, &c) == KERN_SUCCESS else { return nil }
        defer { vm_deallocate(mach_task_self_, p, vm_size_t(c)) }
        return Data(bytes: UnsafeRawPointer(bitPattern: p)!, count: Int(c))
    }
    private func u64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) }
    }
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt32.self) }
    }
    private func i32(_ d: Data, _ o: Int) -> Int32 {
        d.withUnsafeBytes { $0.load(fromByteOffset: o, as: Int32.self) }
    }
    private func isPtr(_ p: UInt64) -> Bool { p > 0x10000 && p < 0x8000_0000_0000 }
    private func cStr(_ addr: UInt64, max: Int = 64) -> String? {
        guard let d = read(addr, max) else { return nil }
        let b = d.prefix { $0 != 0 }
        guard !b.isEmpty, b.count <= 60 else { return nil }
        return String(bytes: b, encoding: .utf8)
    }

    // MARK: setup

    func setup(pid: pid_t) async -> Bool {
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/memory_debug.log")
        func logEngine(_ msg: String) {
            let line = "\(Date.now.formatted(.dateTime.hour().minute().second())) ENGINE: \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
        logEngine("setup start pid=\(pid)")
        reset()
        logEngine("acquireTaskportRightFromMirror...")
        guard acquireTaskportRightFromMirror() else { logEngine("acquireTaskportRightFromMirror FAILED"); return false }
        logEngine("task_for_pid...")
        guard task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { logEngine("task_for_pid FAILED"); return false }
        logEngine("locateMonoChain...")
        guard locateMonoChain() else { logEngine("locateMonoChain FAILED"); return false }
        logEngine("scanClassesAndVtables...")
        guard scanClassesAndVtables() else { logEngine("scanClassesAndVtables FAILED"); return false }
        logEngine("setup SUCCESS classes=\(classByName.count) vtables=\(vtByClass.count)")
        return !classByName.isEmpty && !vtByClass.isEmpty
    }

    private func acquireTaskportRightFromMirror() -> Bool {
        // Call the framework's helper unconditionally: MirrorBridge already
        // acquires the right at attach time, and this call is idempotent.
        // The return value is errno-style; never gate on it. task_for_pid
        // right after is the real test of whether we hold the port.
        _ = acquireTaskportRight()
        return true
    }

    /// dyld image table → libmonobdwgc → _mono_get_root_domain ADRP/LDR decode
    /// → root domain → domain_assemblies GSList → Assembly-CSharp image.
    private func locateMonoChain() -> Bool {
        var info = task_dyld_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / 4)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, 17, $0, &count)
            }
        }
        guard let h = read(info.all_image_info_addr, 16) else { return false }
        let imageCount = Int(h.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        let infoArray = h.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        guard let arr = read(infoArray, imageCount * 24) else { return false }
        for i in 0..<imageCount {
            let loadAddr = arr.withUnsafeBytes { $0.load(fromByteOffset: i * 24, as: UInt64.self) }
            let filePath = arr.withUnsafeBytes { $0.load(fromByteOffset: i * 24 + 8, as: UInt64.self) }
            guard let pd = read(filePath, 512) else { continue }
            if (String(bytes: pd.prefix { $0 != 0 }, encoding: .utf8) ?? "").contains("libmonobdwgc") {
                monoBase = loadAddr
                break
            }
        }
        guard monoBase != 0 else { return false }

        // _mono_get_root_domain @ mono+0x11853c: ADRP X8 + LDR X0,[X8,#0xe80]
        let exportAddr = monoBase + 0x11853c
        guard let ins = read(exportAddr, 8) else { return false }
        let i1 = ins.withUnsafeBytes { $0.load(as: UInt32.self) }
        let i2 = ins.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        var imm = Int((((i1 >> 5) & 0x7FFFF) << 2) | ((i1 >> 29) & 0x3))
        if imm & (1 << 20) != 0 { imm -= 1 << 21 }
        guard let slot = read((exportAddr & ~0xFFF) + UInt64(imm * 4096) + UInt64(((i2 >> 10) & 0xFFF) * 8), 8) else { return false }
        domain = u64(slot, 0)
        guard let dm = read(domain, 0x2000) else { return false }

        var node = dm.withUnsafeBytes { $0.load(fromByteOffset: 0xB0, as: UInt64.self) }
        for _ in 0..<200 {
            guard let d = read(node, 16) else { return false }
            let assembly = d.withUnsafeBytes { $0.load(as: UInt64.self) }
            let next = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
            guard let am = read(assembly, 0x100) else { return false }
            for off in stride(from: 0, to: 0x100, by: 8) {
                let img = am.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self) }
                guard let im = read(img, 0x100) else { continue }
                for io in stride(from: 0, to: 0x100, by: 8) {
                    let np = im.withUnsafeBytes { $0.load(fromByteOffset: io, as: UInt64.self) }
                    let s = read(np, 64).map { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? "" } ?? ""
                    if s == "Assembly-CSharp.dll" {
                        image = img
                        return true
                    }
                }
            }
            guard next != 0 else { return false }
            node = next
        }
        return false
    }

    /// One heap pass: target MonoClasses ([p+0x38]==image, name@0x40) and
    /// vtable candidates ([w]==klass, [w+0x10]==domain). Class candidates are
    /// validated against an anchor field (same-named enums/other classes exist);
    /// vtable resolution prefers initialized candidates but accepts any.
    private func scanClassesAndVtables() -> Bool {
        let targets = Set(["GameState", "ZoneMgr", "Player", "Zone"])
        let anchorField: [String: String] = [
            "GameState": "s_instance",
            "ZoneMgr": "s_instance",
            "Player": "m_local",
            "Zone": "m_cards"
        ]
        var classCandidates: [String: [UInt64]] = [:]
        var vtableCandidates: [(vt: UInt64, klass: UInt64)] = []

        forEachRegion { base, size in
            var offset: UInt64 = 0
            while offset < size {
                let chunk = Int(min(8 * 1024 * 1024, size - offset))
                guard let buf = self.read(base + offset, chunk) else { break }
                buf.withUnsafeBytes { raw in
                    let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
                    let words = chunk / 8
                    for k in 0..<words {
                        guard k + 8 < words else { break }
                        if ptr[k + 7] == self.image {
                            let addr = base + offset + UInt64(k * 8)
                            let np = ptr[k + 8]
                            if self.isPtr(np), let s = self.cStr(np), targets.contains(s) {
                                classCandidates[s, default: []].append(addr)
                            }
                        }
                        if k + 2 < words, ptr[k + 2] == self.domain, self.isPtr(ptr[k]),
                           vtableCandidates.count < 400_000 {
                            vtableCandidates.append((base + offset + UInt64(k * 8), ptr[k]))
                        }
                    }
                }
                offset += UInt64(chunk)
            }
        }

        // Validate: the real class carries its anchor field (same-named enums
        // and compiler-generated classes do not)
        for (name, addrs) in classCandidates {
            guard let anchor = anchorField[name], classByName[name] == nil else { continue }
            for addr in addrs where fields(addr)[anchor] != nil {
                classByName[name] = addr
                break
            }
        }

        // Vtable resolution: keep candidates whose klass is a validated class,
        // preferring initialized vtables (init flag @ vt+0x2F bit 2)
        var klassToName: [UInt64: String] = [:]
        for (name, addr) in classByName { klassToName[addr] = name }
        var vtInit: [String: UInt64] = [:]
        var vtAny: [String: UInt64] = [:]
        for (vt, kl) in vtableCandidates {
            guard let name = klassToName[kl] else { continue }
            if vtAny[name] == nil { vtAny[name] = vt }
            if vtInit[name] == nil, let vm = read(vt, 0x30) {
                let flags: UInt8 = vm.withUnsafeBytes { $0.load(fromByteOffset: 0x2F, as: UInt8.self) }
                if (flags >> 2) & 1 == 1 { vtInit[name] = vt }
            }
        }
        for name in targets {
            if let vt = vtInit[name] ?? vtAny[name] { vtByClass[name] = vt }
        }

        let missingClasses = targets.subtracting(classByName.keys)
        let missingVtables = targets.subtracting(vtByClass.keys)
        let candSummary = classCandidates.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        logEngineScan("scan: classes=\(classByName.keys.sorted().joined(separator: ",")) missingClasses=\(missingClasses.sorted().joined(separator: ",")) vtables=\(vtByClass.keys.sorted().joined(separator: ",")) missingVtables=\(missingVtables.sorted().joined(separator: ",")) candidates=[\(candSummary)] vtCandidates=\(vtableCandidates.count)")
        return classByName.count == targets.count && vtByClass.count == targets.count
    }

    private func logEngineScan(_ msg: String) {
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/memory_debug.log")
        let line = "\(Date.now.formatted(.dateTime.hour().minute().second())) ENGINE: \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func forEachRegion(_ body: (UInt64, UInt64) -> Void) {
        var address: UInt64 = 0x1000
        while true {
            var size: mach_vm_size_t = 0
            var infoAddr = mach_vm_address_t(address)
            var basic = vm_region_basic_info_data_64_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
            var objectName: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &basic) { ptr in
                mach_vm_region(task, &infoAddr, &size,
                    vm_region_flavor_t(VM_REGION_BASIC_INFO_64),
                    UnsafeMutablePointer<integer_t>(OpaquePointer(ptr)), &infoCount, &objectName)
            }
            guard kr == KERN_SUCCESS else { return }
            address = UInt64(infoAddr) + size
            guard basic.protection & VM_PROT_READ != 0, size >= 0x200, size <= (1 << 30) else { continue }
            body(UInt64(infoAddr), size)
        }
    }

    // MARK: fields

    private func fields(_ klass: UInt64) -> [String: Int] {
        if let f = fieldsCache[klass] { return f }
        var map: [String: Int] = [:]
        if let km = read(klass, 0x98), isPtr(u64(km, 0x90)),
           let fm = read(u64(km, 0x90), 0x20 * 200) {
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

    /// data = *(vtable + *(i32*)(klass+0x54)*8 + 0x48); init flag = vtable+0x2F bit2
    private func staticValue(_ clsName: String, _ fieldName: String) -> UInt64? {
        guard let cls = classByName[clsName], let vt = vtByClass[clsName],
              let vm = read(vt, 0x80) else { return nil }
        let flags: UInt8 = vm.withUnsafeBytes { $0.load(fromByteOffset: 0x2F, as: UInt8.self) }
        guard (flags >> 2) & 1 == 1 else { return nil }
        guard let km = read(cls, 0x60) else { return nil }
        let slot = Int(i32(km, 0x54))
        let data = u64(vm, 0x48 + slot * 8)
        guard isPtr(data), let dm = read(data, 0x200) else { return nil }
        let off = fields(cls)[fieldName] ?? -1
        guard off >= 0, off + 8 <= 0x200 else { return nil }
        return u64(dm, off)
    }

    private func objClass(_ obj: UInt64) -> String? {
        guard let om = read(obj, 0x10), isPtr(u64(om, 0)),
              let vm = read(u64(om, 0), 0x10), isPtr(u64(vm, 0)) else { return nil }
        let kl = u64(vm, 0)
        guard let km = read(kl, 0x48), u64(km, 0x38) == image,
              let s = cStr(u64(km, 0x40)) else { return nil }
        return s
    }

    private func listCount(_ v: UInt64) -> Int? {
        guard let m = read(v, 0x20), isPtr(u64(m, 0x10)) else { return nil }
        let sz = Int(Int32(bitPattern: u32(m, 0x18)))
        guard sz >= 0, sz < 100000 else { return nil }
        return sz
    }

    /// List<T> element pointers: _items @ 0x10 (MonoArray, vector @ 0x20), _size @ 0x18.
    private func listElements(_ v: UInt64) -> [UInt64]? {
        guard let m = read(v, 0x20), isPtr(u64(m, 0x10)) else { return nil }
        let sz = Int(Int32(bitPattern: u32(m, 0x18)))
        guard sz >= 0, sz < 1000 else { return nil }
        guard sz > 0 else { return [] }
        guard let arr = read(u64(m, 0x10) + 0x20, sz * 8) else { return nil }
        return (0..<sz).map { index in
            arr.withUnsafeBytes { $0.load(fromByteOffset: index * 8, as: UInt64.self) }
        }
    }

    /// MonoString in this branch (verified): length (i32) @ 0x10, UTF-16LE
    /// code units @ 0x14 — no MonoObject header.
    private func monoString(_ p: UInt64) -> String? {
        guard isPtr(p), let m = read(p, 0x14) else { return nil }
        let len = Int(Int32(bitPattern: u32(m, 0x10)))
        guard len > 0, len <= 80 else { return nil }
        guard let chars = read(p + 0x14, len * 2) else { return nil }
        let units = (0..<len).map { index in
            chars.withUnsafeBytes { $0.load(fromByteOffset: index * 2, as: UInt16.self) }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func isValidCardID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Hand identities: ZoneHand.m_cards → Card.m_entity @ 0x28 → entity
    /// cardID MonoString @ 0x28 (probe-pinned, stage16/stage18). T5 anonymizes
    /// DECK entities (shared empty string) but HAND entities stay readable.
    private func readHandCardIDs(_ list: UInt64) -> [String]? {
        guard let elements = listElements(list) else { return nil }
        var ids: [String] = []
        var unreadable = 0
        for element in elements {
            var cardID: String?
            if isPtr(element), let cm = read(element, 0x30) {
                let cardEntity = u64(cm, 0x28)
                if isPtr(cardEntity), let em = read(cardEntity, 0x30) {
                    cardID = monoString(u64(em, 0x28))
                }
            }
            if let cardID, isValidCardID(cardID) {
                ids.append(cardID)
            } else {
                unreadable += 1
            }
        }
        if unreadable > 0 {
            logEngineScan("hand: \(unreadable)/\(elements.count) cardIDs unreadable")
        }
        return ids.isEmpty ? nil : ids
    }

    // MARK: poll

    func poll() -> Snapshot {
        var snap = Snapshot()
        guard classByName.count > 0, vtByClass.count > 0 else {
            logEngineScan("poll: no classes/vtables")
            return snap
        }

        guard let gs = staticValue("GameState", "s_instance"), isPtr(gs) else {
            if lastPollSummary != "idle" {
                lastPollSummary = "idle"
                logEngineScan("poll: not in match (GameState.s_instance nil)")
            }
            snap.inMatch = false
            return snap
        }
        guard let zm = staticValue("ZoneMgr", "s_instance"), isPtr(zm) else {
            if lastPollSummary != "idle" {
                lastPollSummary = "idle"
                logEngineScan("poll: not in match (ZoneMgr.s_instance nil)")
            }
            snap.inMatch = false
            return snap
        }
        guard let zonesOff = fields(classByName["ZoneMgr"]!)["m_zones"],
              let zmem = read(zm, zonesOff + 8), isPtr(u64(zmem, zonesOff)) else {
            logEngineScan("poll: m_zones field/read fail, off=\(fields(classByName["ZoneMgr"]!)["m_zones"] ?? -1)")
            return snap
        }
        let zonesList = u64(zmem, zonesOff)
        guard let lm = read(zonesList, 0x20), isPtr(u64(lm, 0x10)) else {
            logEngineScan("poll: zones list read fail")
            return snap
        }
        let size = Int(Int32(bitPattern: u32(lm, 0x18)))
        guard size >= 0, size < 200 else {
            logEngineScan("poll: zones size weird=\(size)")
            return snap
        }
        let arr = u64(lm, 0x10)
        guard size == 0 || read(arr + 0x20, size * 8) != nil else {
            logEngineScan("poll: zones array read fail")
            return snap
        }

        let zoneFields = fields(classByName["Zone"]!)
        let playerFields = fields(classByName["Player"]!)
        let localOff = playerFields["m_local"] ?? -1

        var counts = MirrorMemoryStore.ZoneCounts()
        var sawLocalSide = false
        var localHandList: UInt64?
        if let data = size > 0 ? read(arr + 0x20, size * 8) : Data() {
            for e in 0..<size {
                let zone = data.withUnsafeBytes { $0.load(fromByteOffset: e * 8, as: UInt64.self) }
                guard isPtr(zone), let zmem2 = read(zone, 0x100) else { continue }
                // zone class name via its vtable (cached per vtable pointer)
                guard isPtr(u64(zmem2, 0)), let vtm = read(u64(zmem2, 0), 0x10),
                      isPtr(u64(vtm, 0)) else { continue }
                let vtPtr = u64(zmem2, 0)
                let kind: String
                if let cached = zoneKindCache[vtPtr] {
                    kind = cached
                } else if let n = objClass(zone) {
                    kind = n
                    zoneKindCache[vtPtr] = n
                } else { continue }

                var cardCount: Int?
                if let co = zoneFields["m_cards"], isPtr(u64(zmem2, co)) {
                    cardCount = listCount(u64(zmem2, co))
                }
                // controller → Player → m_local determines the friendly side
                var isLocal = false
                if let co = zoneFields["m_controller"], isPtr(u64(zmem2, co)) {
                    let player = u64(zmem2, co)
                    if localOff >= 0, let pm = read(player, localOff + 1) {
                        isLocal = pm.withUnsafeBytes { $0.load(fromByteOffset: localOff, as: UInt8.self) } != 0
                    }
                }
                if isLocal { sawLocalSide = true }

                switch kind {
                case "ZoneHand":
                    if isLocal {
                        if counts.friendlyHand == nil { counts.friendlyHand = cardCount }
                        if localHandList == nil, let co = zoneFields["m_cards"], isPtr(u64(zmem2, co)) {
                            localHandList = u64(zmem2, co)
                        }
                    }
                    else { if counts.opponentHand == nil { counts.opponentHand = cardCount } }
                case "ZoneDeck":
                    if isLocal { if counts.friendlyDeck == nil { counts.friendlyDeck = cardCount } }
                    else { if counts.opponentDeck == nil { counts.opponentDeck = cardCount } }
                case "ZonePlay":
                    if isLocal { if counts.friendlyBoard == nil { counts.friendlyBoard = cardCount } }
                    else { if counts.opponentBoard == nil { counts.opponentBoard = cardCount } }
                default:
                    continue
                }
            }
        }
        snap.inMatch = sawLocalSide
        snap.counts = sawLocalSide ? counts : nil
        if sawLocalSide, let handList = localHandList {
            snap.handCardIDs = readHandCardIDs(handList)
        }
        if !sawLocalSide {
            if lastPollSummary != "noLocal" {
                lastPollSummary = "noLocal"
                logEngineScan("poll: no local side found among \(size) zones")
            }
        } else {
            let summary = "fH=\(counts.friendlyHand ?? -1) oH=\(counts.opponentHand ?? -1) fD=\(counts.friendlyDeck ?? -1) oD=\(counts.opponentDeck ?? -1) fB=\(counts.friendlyBoard ?? -1) oB=\(counts.opponentBoard ?? -1)"
            if lastPollSummary != summary {
                lastPollSummary = summary
                logEngineScan("poll OK: \(summary)")
            }
        }
        return snap
    }
}
