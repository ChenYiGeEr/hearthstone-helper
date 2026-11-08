import Foundation
import Observation
import HearthstoneCore

/// One finished match as kept for statistics; win rates only count complete
/// records with a known outcome (honest-data rule). The card snapshots back
/// the post-game detail view and are optional so older history files load.
struct MatchHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    let deckName: String
    let deckID: Int?
    let opponentClass: String
    let result: MatchOutcome
    let integrity: MatchIntegrity
    var opponentCards: [TrackedCard]?
    var playerPlayedCards: [TrackedCard]?
    var playerRemainingCards: [TrackedCard]?
    var opponentAccountID: String?
    /// Hero cardID (for example `HERO_08`) before the class name is localized.
    /// Deckstring export needs this; a Chinese class label is not a hero.
    var opponentHeroCardID: String?
    var format: String?
    var mulliganKept: [String]?
    var mulliganDiscarded: [String]?
    var turns: [TurnLog]?

    var countsTowardWinRate: Bool {
        integrity == .complete && result != .tie
    }
}

@MainActor
@Observable
final class MatchHistoryStore {
    private(set) var entries: [MatchHistoryEntry] = []

    private static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearthstoneHelper/history.json")
    }

    init() {
        load()
    }

    func appendIfNeeded(
        from record: MatchRecord,
        format: String? = nil,
        opponentHeroCardID: String? = nil
    ) {
        guard let result = record.result else { return }
        let entry = MatchHistoryEntry(
            id: record.id,
            startedAt: record.startedAt,
            deckName: record.playerDeckName,
            deckID: record.playerDeckID,
            opponentClass: record.opponentClass,
            result: result,
            integrity: record.integrity,
            opponentCards: record.opponentCards,
            playerPlayedCards: record.playerPlayedCards,
            playerRemainingCards: record.playerRemainingCards,
            opponentAccountID: record.opponentAccountID,
            opponentHeroCardID: opponentHeroCardID,
            format: format,
            mulliganKept: record.mulliganKept,
            mulliganDiscarded: record.mulliganDiscarded,
            turns: record.turns
        )
        // content dedup: replays of the same game must not append twice even
        // across app restarts (same opponent, deck, outcome and start time)
        guard !entries.contains(where: { Self.contentKey($0) == Self.contentKey(entry) }) else {
            return
        }
        entries.append(entry)
        save()
    }

    private static func contentKey(_ entry: MatchHistoryEntry) -> String {
        "\(entry.startedAt.timeIntervalSince1970)|\(entry.deckID ?? -1)|\(entry.opponentAccountID ?? "-")|\(entry.result.rawValue)"
    }

    /// Rewrites raw hero cardIDs (e.g. HERO_04bc) into Chinese class names
    /// once the card catalog is available; entries appended before the catalog
    /// finished loading store raw values.
    func relocalize(catalog: CardCatalog) {
        var changed = false
        entries = entries.map { entry in
            guard let localized = catalog.classDisplayName(forHeroCardID: entry.opponentClass),
                  localized != entry.opponentClass
            else { return entry }
            changed = true
            let heroCardID = entry.opponentHeroCardID ?? entry.opponentClass
            return MatchHistoryEntry(
                id: entry.id,
                startedAt: entry.startedAt,
                deckName: entry.deckName,
                deckID: entry.deckID,
                opponentClass: localized,
                result: entry.result,
                integrity: entry.integrity,
                opponentCards: entry.opponentCards,
                playerPlayedCards: entry.playerPlayedCards,
                playerRemainingCards: entry.playerRemainingCards,
                opponentAccountID: entry.opponentAccountID,
                opponentHeroCardID: heroCardID,
                format: entry.format,
                mulliganKept: entry.mulliganKept,
                mulliganDiscarded: entry.mulliganDiscarded,
                turns: entry.turns
            )
        }
        if changed { save() }
    }

    // MARK: - Statistics

    struct DeckStats: Equatable {
        var games = 0
        var wins = 0
        var losses = 0
        var ties = 0

        var winRate: Double {
            games == 0 ? 0 : Double(wins) / Double(wins + losses)
        }
    }

    func stats(deckID: Int?) -> DeckStats {
        stats { $0.deckID == deckID }
    }

    func stats(deckName: String) -> DeckStats {
        stats { $0.deckName == deckName }
    }

    func stats(againstClass className: String, deckID: Int?) -> DeckStats {
        stats { $0.opponentClass == className && $0.deckID == deckID }
    }

    func recentMatches(deckID: Int?, limit: Int = 15) -> [MatchHistoryEntry] {
        entries
            .filter { $0.deckID == deckID }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0 }
    }

    private func stats(_ matching: (MatchHistoryEntry) -> Bool) -> DeckStats {
        var result = DeckStats()
        for entry in entries where matching(entry) && entry.integrity == .complete {
            switch entry.result {
            case .win:
                result.wins += 1
                result.games += 1
            case .loss:
                result.losses += 1
                result.games += 1
            case .tie:
                result.ties += 1
            }
        }
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard
            let data = try? Data(contentsOf: Self.storageURL),
            let decoded = try? JSONDecoder().decode([MatchHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: Self.storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }
}
