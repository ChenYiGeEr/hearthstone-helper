import Foundation
import Observation
import HearthstoneCore

/// The user's deck library, synced automatically from every Decks.log the
/// client has written (login dumps + edits). No manual import anywhere.
@MainActor
@Observable
final class DeckLibraryStore {
    struct DeckSummary: Identifiable, Hashable {
        let id: Int
        let name: String
        let code: String
        var className: String
        var formatName: String = "未知"
        var cardCount: Int
        /// (cardID, count) resolved through the card catalog; empty until a
        /// catalog is available.
        var cards: [(cardID: String, count: Int)] = []
        /// Mana curve: index 0–6 is that cost, index 7 means 7+.
        var curve: [Int] = []
        /// Type composition, e.g. 随从 15 / 法术 10 / 武器 2 / 任务 1.
        var typeCounts: [(label: String, count: Int)] = []

        // 内容级相等:refresh 会用 catalog 补全同一批 id 的卡组
        // (未知→标准/战士/构成),SwiftUI 依赖 == 判断行是否需要重绘。
        static func == (lhs: DeckSummary, rhs: DeckSummary) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.code == rhs.code
                && lhs.className == rhs.className
                && lhs.formatName == rhs.formatName
                && lhs.cardCount == rhs.cardCount
                && lhs.cards.map { "\($0.cardID)#\($0.count)" } == rhs.cards.map { "\($0.cardID)#\($0.count)" }
                && lhs.curve == rhs.curve
                && lhs.typeCounts.map(\.label) == rhs.typeCounts.map(\.label)
                && lhs.typeCounts.map(\.count) == rhs.typeCounts.map(\.count)
        }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private(set) var decks: [DeckSummary] = []
    private var byID: [Int: DecksLogFile.DeckEntry] = [:]

    private static var logDirectories: [URL] {
        HearthstoneLogLocator.powerLogDirectories
    }

    /// Current collection = the LAST full login dump in the file (consecutive
    /// "Deck Contents Received" entries sharing one timestamp), overlaid by
    /// every later edit/queue event.
    static func currentCollection(_ file: DecksLogFile) -> [Int: DecksLogFile.DeckEntry] {
        let entries = file.entries
        // find the last run of consecutive .contents entries
        var dumpStart: Int?
        var index = 0
        while index < entries.count {
            if entries[index].marker == .contents {
                var end = index
                while end + 1 < entries.count, entries[end + 1].marker == .contents {
                    end += 1
                }
                dumpStart = index
                index = end + 1
            } else {
                index += 1
            }
        }

        var collection: [Int: DecksLogFile.DeckEntry] = [:]
        if let dumpStart {
            for entry in entries[dumpStart...] where entry.marker == .contents {
                collection[entry.deckID] = entry
            }
        }

        // overlay later edits / queued decks (by dump time of the last dump)
        let dumpTime = dumpStart.map { entries[$0].time } ?? ""
        for entry in entries {
            let afterDump = dumpTime.isEmpty || entry.time > dumpTime
            if entry.marker != .contents && afterDump {
                collection[entry.deckID] = entry
            }
        }
        return collection
    }

    /// Deckstring for a memory-read deck. Nil when the hero or any card has no
    /// dbfId, so the clipboard is never filled with an empty or partial code.
    private static func deckCode(for deck: MirrorLiveStore.OwnDeck, catalog: CardCatalog) -> String? {
        guard catalog.classDisplayName(forHeroCardID: deck.heroCardID) != nil,
              let heroDbfID = catalog.info(for: deck.heroCardID)?.dbfId
        else { return nil }
        var cards: [(dbfID: Int, count: Int)] = []
        for card in deck.cards where card.count > 0 {
            guard let dbfID = catalog.info(for: card.cardID)?.dbfId else { return nil }
            cards.append((dbfID, card.count))
        }
        guard !cards.isEmpty else { return nil }
        let format = deck.formatType > 0 ? deck.formatType : 2
        return DeckCode.encode(heroDbfID: heroDbfID, cards: cards, format: format)
    }

    /// Rebuilds the library. Mirror decks (exact, from client memory) take
    /// priority; the newest Decks.log session is the fallback when the mirror
    /// has not delivered yet.
    func refresh(catalog: CardCatalog?, mirrorDecks: [MirrorLiveStore.OwnDeck] = []) {
        if !mirrorDecks.isEmpty {
            decks = mirrorDecks.map { deck in
                var summary = DeckSummary(
                    id: deck.id,
                    name: deck.name,
                    code: catalog.flatMap { Self.deckCode(for: deck, catalog: $0) } ?? "",
                    className: catalog?.classLabel(for: deck.heroCardID) ?? "未知",
                    formatName: deck.formatType == 2 ? "标准" : deck.formatType == 1 ? "狂野" : "未知",
                    cardCount: deck.cards.reduce(0) { $0 + $1.count }
                )
                if let catalog {
                    summary.cards = deck.cards.sorted {
                        (catalog.cost(for: $0.cardID) ?? 0, $0.cardID)
                            < (catalog.cost(for: $1.cardID) ?? 0, $1.cardID)
                    }
                    summary.curve = Self.manaCurve(of: summary.cards, catalog: catalog)
                    summary.typeCounts = Self.typeBreakdown(of: summary.cards, catalog: catalog)
                }
                return summary
            }
            return
        }
        refreshFromLog(catalog: catalog)
    }

    /// Log-based fallback (kept for clients/mirror failures).
    private func refreshFromLog(catalog: CardCatalog?) {
        // Without the catalog the rebuild would publish decks with
        // formatName "未知", which the standard filter hides — the sidebar
        // would sit blank until the next refresh. Keep the previous state
        // and wait for the catalog; bootstrap re-refreshes once it's ready.
        guard let catalog else { return }

        // newest session that actually contains deck entries
        var newestEntryFile: (URL, Date)?
        for directory in Self.logDirectories {
            let sessionKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: sessionKeys, options: [.skipsHiddenFiles]
                )
            else { continue }

            for session in entries where session.lastPathComponent.hasPrefix("Hearthstone_") {
                let decksLogURL = session.appendingPathComponent("Decks.log")
                guard let values = try? decksLogURL.resourceValues(forKeys: Set(sessionKeys)),
                      values.isDirectory != true,
                      let modified = values.contentModificationDate
                else { continue }
                if newestEntryFile == nil || modified > newestEntryFile!.1 {
                    newestEntryFile = (decksLogURL, modified)
                }
            }
        }

        guard let fileURL = newestEntryFile?.0,
              let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }

        byID = Self.currentCollection(DecksLogFile.parse(text))

        decks = byID.values
            .sorted { $0.name < $1.name }            .map { entry in
                var summary = DeckSummary(
                    id: entry.deckID,
                    name: entry.name,
                    code: entry.code,
                    className: "未知",
                    cardCount: 0
                )
                if let decoded = DeckCode.decode(entry.code) {
                    summary.cardCount = decoded.totalCardCount
                    // The deckstring's own format byte is unreliable in this
                    // client (always 2), so legality is judged by content:
                    // a deck is Standard iff every known card is Standard-legal
                    let cardIDs = decoded.cards.compactMap { catalog.cardID(forDbfID: $0.dbfID) }
                    let known = cardIDs.filter { catalog.info(for: $0)?.set != nil }
                    if known.isEmpty {
                        summary.formatName = "未知"
                    } else if known.allSatisfy({ catalog.isStandard($0) }) {
                        summary.formatName = "标准"
                    } else {
                        summary.formatName = "狂野"
                    }
                    if
                        let heroCardID = catalog.cardID(forDbfID: decoded.heroDbfID),
                        let className = catalog.classDisplayName(forHeroCardID: heroCardID)
                    {
                        summary.className = className
                    }
                    summary.cards = decoded.cards.compactMap { ref in
                        guard let cardID = catalog.cardID(forDbfID: ref.dbfID) else { return nil }
                        return (cardID, ref.count)
                    }
                    .sorted { lhs, rhs in
                        (catalog.cost(for: lhs.cardID) ?? 0, lhs.cardID)
                            < (catalog.cost(for: rhs.cardID) ?? 0, rhs.cardID)
                    }
                    summary.curve = Self.manaCurve(of: summary.cards, catalog: catalog)
                    summary.typeCounts = Self.typeBreakdown(of: summary.cards, catalog: catalog)
                }
                return summary
            }
    }

    private static func manaCurve(
        of cards: [(cardID: String, count: Int)],
        catalog: CardCatalog
    ) -> [Int] {
        var curve = Array(repeating: 0, count: 8)
        for (cardID, count) in cards {
            curve[min(catalog.cost(for: cardID) ?? 0, 7)] += count
        }
        return curve
    }

    private static let typeOrder = ["随从", "法术", "武器", "任务", "英雄", "地标", "其他"]

    private static func typeBreakdown(
        of cards: [(cardID: String, count: Int)],
        catalog: CardCatalog
    ) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (cardID, count) in cards {
            let info = catalog.info(for: cardID)
            let text = info?.text ?? ""
            let label: String
            if text.contains("任务：") || text.contains("支线任务") {
                label = "任务"
            } else {
                switch info?.type {
                case "MINION": label = "随从"
                case "SPELL": label = "法术"
                case "WEAPON": label = "武器"
                case "HERO": label = "英雄"
                case "LOCATION": label = "地标"
                default: label = "其他"
                }
            }
            counts[label, default: 0] += count
        }
        return typeOrder.compactMap { label in counts[label].map { (label, $0) } }
    }
}
