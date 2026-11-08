import AppKit
import Foundation
import HearthstoneCore

/// Where the match pipeline currently stands; drives the header status and the
/// first-run configuration guide. Lifecycle per the confirmed state machine:
/// 未登录 → 已登录 → 游戏中 → 已结束 →（游戏中 | 未登录）.
enum LogPipelineStatus: Equatable {
    /// No log.config found — the client writes no Power.log until logging is enabled.
    case missingLogConfig
    /// The Hearthstone client process is not running.
    case notRunning
    /// Client is running but no match has been played in its current session.
    case loggedIn
    /// A match is being recorded from a growing Power.log.
    case live(MatchRecord)
    /// Memory still sees a match, but Power.log has stopped growing, so
    /// opponent reveals cannot advance. Not a healthy live feed.
    case logStalled(MatchRecord)
    /// The recorded match reached its end (STATE=COMPLETE).
    case finished(MatchRecord)

    var match: MatchRecord? {
        switch self {
        case let .live(record), let .logStalled(record), let .finished(record): record
        default: nil
        }
    }
}

enum HearthstoneLogLocator {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The modern Unity client reads log.config from its persistentDataPath and
    /// writes logs under ~/Library/Logs/Blizzard Entertainment/Hearthstone; the
    /// older Preferences path is kept as a fallback for other client versions.
    /// The T5 client logs into timestamped session folders (`Hearthstone_yyyy_MM_dd…`)
    /// under `<game install>/Logs`; each client restart begins a new session.
    /// The ~/Library locations cover older client builds.
    static var powerLogDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications/Hearthstone/Logs", isDirectory: true),
            home.appendingPathComponent("Library/Logs/Hearthstone", isDirectory: true),
            home.appendingPathComponent("Library/Logs/Blizzard Entertainment/Hearthstone", isDirectory: true)
        ]
    }

    /// Folder that holds the freshest Power.log. Directory mtime does not move
    /// when a log is appended, so it must not be used to pick the session.
    static var currentSessionDirectory: URL? {
        currentSessionPowerLogURL?.deletingLastPathComponent()
    }

    /// Power.log with the newest file mtime, across every known root and every
    /// `Hearthstone_*` session folder. A restarted client gets a new file and
    /// the tailer follows it on the next poll.
    static var currentSessionPowerLogURL: URL? {
        freshestPowerLog()
    }

    /// How long Power.log may sit unchanged before it is treated as stalled.
    static let powerLogStallInterval: TimeInterval = 30

    static func freshestPowerLog(fileManager: FileManager = .default) -> URL? {
        var best: (URL, Date)?
        func consider(_ url: URL) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || modified > best!.1 {
                best = (url, modified)
            }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        for root in powerLogDirectories {
            consider(root.appendingPathComponent("Power.log"))
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                )
            else { continue }
            for url in entries where url.lastPathComponent.hasPrefix("Hearthstone_") {
                guard (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true else { continue }
                consider(url.appendingPathComponent("Power.log"))
            }
        }
        return best?.0
    }

    static func powerLogByteCount(_ url: URL, fileManager: FileManager = .default) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Whether the Hearthstone client process is currently running.
    @MainActor
    static var isHearthstoneRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
        }
    }

    static var logConfigURLs: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/unity.Blizzard Entertainment.Hearthstone/log.config"),
            home.appendingPathComponent("Library/Preferences/Blizzard/Hearthstone/log.config"),
            home.appendingPathComponent("Library/Application Support/Blizzard/Hearthstone/log.config")
        ]
    }

    /// Minimal verbosity config. The T5 client reads `MinLevel` (numeric) while
    /// older builds read `LogLevel`, so each logger carries both keys. Console/
    /// Screen output stay off so the game process is not disturbed. Decks.log
    /// carries deck codes for future deck matching.
    static let logConfigContent = """
        [Zone]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false

        [Power]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false

        [PowerTaskList]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false

        [GameState]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false

        [Loader]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false

        [Decks]
        MinLevel=1
        LogLevel=1
        FilePrinting=true
        ConsolePrinting=false
        Console=false
        ScreenPrinting=false
        Screen=false
        """

    static func isLogConfigPresent() -> Bool {
        logConfigURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writes the logging config to every known macOS location so any client
    /// version picks it up on its next launch.
    static func writeLogConfig() throws {
        for url in logConfigURLs {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try logConfigContent.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}

/// Polls Power.log on the main run loop, feeding appended events into the session
/// tracker and publishing pipeline status updates. A read failure or log rotation
/// simply drops the tailer; the next poll rebuilds it from the current file.
@MainActor
final class PowerLogMonitor {
    var onStatus: (@MainActor (LogPipelineStatus) -> Void)?
    /// Resolves a deck code into its (cardID × count) list; injected by the
    /// store so the tracker can show the deck-view remaining cards.
    var deckListResolver: (@MainActor (String) -> [(cardID: String, count: Int)])?
    /// True while MirrorMemory still sees a match. A stalled Power.log during
    /// that window is not a healthy live feed.
    var memoryInMatch: (@MainActor () -> Bool)?

    private var timer: Timer?
    private var tailer: PowerLogTailer?
    private var tailerURL: URL?
    private var tracker = MatchSessionTracker()
    private var lastStatus: LogPipelineStatus?
    private var watchedByteCount: Int?
    private var watchedByteChangedAt = Date()
    private var powerLogStalled = false
    private var didLogStall = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        // The first poll can read a multi-megabyte Power.log. Do not run it
        // on the caller's stack: MatchStore.begin() is what shows the window.
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard HearthstoneLogLocator.isLogConfigPresent() else {
            publishIfKindChanged(.missingLogConfig)
            return
        }

        // state machine: 未登录 (client down) → 已登录 (up, no match yet)
        guard HearthstoneLogLocator.isHearthstoneRunning else {
            tailer = nil
            publishIfKindChanged(.notRunning)
            return
        }

        guard let url = HearthstoneLogLocator.currentSessionPowerLogURL else {
            // client is up but this session has no match yet; do NOT fall back
            // to an older session's Power.log (that resurrects finished games)
            tailer = nil
            publishIfKindChanged(.loggedIn)
            return
        }

        let switchedFile = tailerURL != url
        if switchedFile {
            watchedByteCount = nil
            watchedByteChangedAt = Date()
            powerLogStalled = false
            didLogStall = false
        }
        notePowerLogGrowth(url)

        // Rebuild only when the file is new, the handle was dropped after a
        // read error, or the client rotated to a fresher Power.log. A healthy
        // incremental tail must not re-read the whole file: that re-fires
        // CREATE_GAME and associateDeck against a log that is not growing.
        if tailer == nil || switchedFile {
            logDiagnostic("tailer rebuild for \(url.lastPathComponent)")
            tailerURL = url
            tailer = PowerLogTailer(fileURL: url)
            tracker = MatchSessionTracker()
            currentDeck = nil
        }

        guard var activeTailer = tailer else { return }
        do {
            let events = try activeTailer.readNewEvents()
            tailer = activeTailer
            guard !events.isEmpty else {
                publishIfKindChanged(feedStatus())
                return
            }
            for event in events {
                tracker.apply(event)
                if case .gameCreated = event {
                    associateDeck(logTime: activeTailer.lastTimestamp)
                    gameStartLogTime = activeTailer.lastTimestamp
                }
            }
            publish(feedStatus())
        } catch {
            logDiagnostic("read error: \(error.localizedDescription)")
            tailer = nil
        }
    }

    /// Byte count unchanged for `powerLogStallInterval` means the client still
    /// has the file open but is not appending. Memory can keep a match alive
    /// after that; the log replay must not keep looking like a healthy feed.
    private func notePowerLogGrowth(_ url: URL) {
        let size = HearthstoneLogLocator.powerLogByteCount(url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if watchedByteCount != size {
            watchedByteCount = size
            if let modified, Date().timeIntervalSince(modified) >= HearthstoneLogLocator.powerLogStallInterval {
                watchedByteChangedAt = modified
                markPowerLogStalled(bytes: size)
            } else {
                watchedByteChangedAt = Date()
                powerLogStalled = false
                didLogStall = false
            }
            return
        }
        if let modified, modified < watchedByteChangedAt {
            watchedByteChangedAt = modified
        }
        guard Date().timeIntervalSince(watchedByteChangedAt) >= HearthstoneLogLocator.powerLogStallInterval else {
            return
        }
        markPowerLogStalled(bytes: size)
    }

    private func markPowerLogStalled(bytes: Int) {
        powerLogStalled = true
        guard !didLogStall else { return }
        didLogStall = true
        let inMatch = memoryInMatch?() == true
        logDiagnostic("Power.log stalled at \(bytes) bytes; memory inMatch=\(inMatch)")
    }

    private func feedStatus() -> LogPipelineStatus {
        let base = currentStatus()
        guard powerLogStalled, case let .live(record) = base else { return base }
        if memoryInMatch?() == true {
            return .logStalled(record)
        }
        return .loggedIn
    }

    /// Attributes the game that just started to the deck queued in Decks.log.
    /// Both files share the client's clock within one session, so the latest
    /// "Finding Game With Deck" at or before CREATE_GAME is the deck in use.
    private func associateDeck(logTime: String?) {
        currentDeck = nil
        guard
            let logTime,
            let sessionDirectory = tailerURL?.deletingLastPathComponent()
        else { return }

        let decksLogURL = sessionDirectory.appendingPathComponent("Decks.log")
        guard let text = try? String(contentsOf: decksLogURL, encoding: .utf8) else { return }
        currentDeck = DecksLogFile.parse(text).deckUsed(at: logTime)
        if let deck = currentDeck {
            tracker.setDeckList(deckListResolver?(deck.code) ?? [])
            logDiagnostic("match deck: \(deck.name) (queued \(deck.time), game \(logTime))")
        } else {
            tracker.setDeckList([])
            logDiagnostic("match deck: not found (game \(logTime))")
        }
    }

    /// Re-stamps the record with the log's own CREATE_GAME time so replays
    /// of the same game carry an identical startedAt (dedup + display).
    private func annotateStart(_ record: MatchRecord) -> MatchRecord {
        guard let logTime = gameStartLogTime,
              let date = Self.parseLogTime(logTime, on: Date.now),
              date != record.startedAt
        else { return record }
        return MatchRecord(
            id: record.id,
            playerDeckName: record.playerDeckName,
            playerDeckID: record.playerDeckID,
            opponentClass: record.opponentClass,
            startedAt: date,
            integrity: record.integrity,
            result: record.result,
            friendlyStats: record.friendlyStats,
            opponentStats: record.opponentStats,
            turnStartedAt: record.turnStartedAt,
            currentActorIsOpponent: record.currentActorIsOpponent,
            opponentAccountID: record.opponentAccountID,
            revealedSecrets: record.revealedSecrets,
            mulliganKept: record.mulliganKept,
            mulliganDiscarded: record.mulliganDiscarded,
            turns: record.turns,
            playerHandCards: record.playerHandCards,
            playerRemainingCards: record.playerRemainingCards,
            playerShuffledCards: record.playerShuffledCards,
            playerPlayedCards: record.playerPlayedCards,
            opponentCards: record.opponentCards,
            candidate: record.candidate
        )
    }

    /// "HH:MM:SS.ffffff" on today's date.
    static func parseLogTime(_ stamp: String, on day: Date) -> Date? {
        let parts = stamp.split(separator: ".")[0].split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(
            bySettingHour: parts[0], minute: parts[1], second: parts[2], of: day
        )
    }

    private var currentDeck: DecksLogFile.DeckEntry?
    /// CREATE_GAME's log timestamp of the current game — replay-stable match
    /// identity, so history dedup survives app restarts.
    private var gameStartLogTime: String?

    private func currentStatus() -> LogPipelineStatus {
        guard var record = tracker.snapshot() else { return .loggedIn }
        record = annotateStart(record)

        let annotated: MatchRecord
        if let deck = currentDeck {
            annotated = MatchRecord(
                id: record.id,
                playerDeckName: deck.name,
                playerDeckID: deck.deckID,
                opponentClass: record.opponentClass,
                startedAt: record.startedAt,
                integrity: record.integrity,
                result: record.result,
                friendlyStats: record.friendlyStats,
                opponentStats: record.opponentStats,
                turnStartedAt: record.turnStartedAt,
                currentActorIsOpponent: record.currentActorIsOpponent,
                opponentAccountID: record.opponentAccountID,
                revealedSecrets: record.revealedSecrets,
                mulliganKept: record.mulliganKept,
                mulliganDiscarded: record.mulliganDiscarded,
                turns: record.turns,
                playerHandCards: record.playerHandCards,
                playerRemainingCards: record.playerRemainingCards,
                playerShuffledCards: record.playerShuffledCards,
                playerPlayedCards: record.playerPlayedCards,
                opponentCards: record.opponentCards,
                candidate: record.candidate
            )
        } else {
            annotated = record
        }

        return tracker.isMatchOver ? .finished(annotated) : .live(annotated)
    }

    // MARK: - Diagnostics

    private static var diagnosticsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/monitor.log")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Append-only diagnostic trail for tailer rebuilds and read errors; capped
    /// so it cannot grow unbounded.
    private func logDiagnostic(_ message: String) {
        let url = Self.diagnosticsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let stamp = Self.timestampFormatter.string(from: Date.now)
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func publish(_ status: LogPipelineStatus) {
        lastStatus = status
        onStatus?(status)
    }

    /// snapshot() mints fresh UUIDs on every call, so republishing without new
    /// events would churn the UI; only state-kind transitions republish.
    private func publishIfKindChanged(_ status: LogPipelineStatus) {
        guard !sameKind(status, lastStatus ?? .missingLogConfig) else { return }
        publish(status)
    }

    private func sameKind(_ lhs: LogPipelineStatus, _ rhs: LogPipelineStatus) -> Bool {
        switch (lhs, rhs) {
        case (.missingLogConfig, .missingLogConfig),
             (.notRunning, .notRunning),
             (.loggedIn, .loggedIn),
             (.live, .live),
             (.logStalled, .logStalled),
             (.finished, .finished):
            return true
        default:
            return false
        }
    }
}
