import AppKit
import Foundation
import HearthMirror

/// Swift bridge to the HearthMirror framework (memory reading).
/// Owns the per-game mirror instance and exposes the menu-level authoritative
/// data: the local BattleTag, the deck library, and the current log session dir.
@MainActor
final class MirrorBridge {
    static let shared = MirrorBridge()

    private var mirror: HearthMirror?
    private var mirrorPID: pid_t = 0

    private(set) var battleTag: String?
    private(set) var decks: [(name: String, hero: String, cardCount: Int)] = []
    private(set) var logSessionDir: String?
    private(set) var isAttached = false

    /// Attaches (or re-attaches) the mirror to the running Hearthstone process.
    /// The first attach may surface a system task-port permission prompt.
    func attachIfNeeded() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
        }
        guard let app = apps.first else {
            mirror = nil
            isAttached = false
            return
        }
        guard mirror == nil || mirrorPID != app.processIdentifier else { return }

        // blocking: false — never hang the caller; retry on the next tick.
        // acquireTaskportRight() must precede init: the system may prompt for
        // the task-port permission on first attach.
        _ = acquireTaskportRight()
        guard let created = MirrorFaultGuard.protect({
            HearthMirror(pid: app.processIdentifier, blocking: false)
        }) else {
            mirror = nil
            isAttached = false
            return
        }
        mirror = created
        mirrorPID = app.processIdentifier
        isAttached = true
        refreshReadouts()
        Self.logDiagnostic("mirror attached pid=\(app.processIdentifier) tag=\(battleTag ?? "?") session=\(logSessionDir ?? "?")")
    }

    private static func logDiagnostic(_ message: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/mirror.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let line = "\(Date.now.formatted(.dateTime.hour().minute().second())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func refreshReadouts() {
        guard let mirror else { return }
        guard let reading = MirrorFaultGuard.protect({ () -> (String?, String?, [(String, String, Int)]) in
            let tag = mirror.getBattleTag()
            let session = mirror.getLogSessionDir()
            let decks = mirror.getDecks().map {
                (name: $0.name ?? "?", hero: $0.hero ?? "?", cardCount: $0.cards.count)
            }
            return (tag, session, decks)
        }) else {
            self.mirror = nil
            isAttached = false
            return
        }
        battleTag = reading.0
        logSessionDir = reading.1
        decks = reading.2
    }

    /// Reads the opponent's name while a match is running (nil outside a match).
    func opponentName() -> String? {
        guard let mirror else { return nil }
        guard let name = MirrorFaultGuard.protect({ mirror.getMatchInfo()?.opposingPlayer.name }) else {
            self.mirror = nil
            isAttached = false
            return nil
        }
        return name
    }
}
