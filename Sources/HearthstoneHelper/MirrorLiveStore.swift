import Foundation
import HearthMirror

/// Live data read from the Hearthstone client's memory via HearthMirror.
/// Polls once per second and publishes the authoritative menu-level state:
/// BattleTag, deck library, selected deck, match info, ranks, collection.
@MainActor
@Observable
final class MirrorLiveStore {
    private(set) var attached = false
    private(set) var battleTag: String?

    struct OwnDeck: Identifiable, Hashable {
        let id: Int
        let name: String
        let heroCardID: String
        let formatType: Int
        let cards: [(cardID: String, count: Int)]

        static func == (lhs: OwnDeck, rhs: OwnDeck) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    private(set) var ownDecks: [OwnDeck] = []
    private(set) var selectedDeckID: Int?
    private(set) var selectedDeckName: String?

    /// LeagueId 0-5 = 青铜~传说；nil = 未知
    static func leagueName(_ leagueID: Int?) -> String? {
        guard let leagueID, (0...5).contains(leagueID) else { return nil }
        return ["青铜", "白银", "黄金", "铂金", "钻石", "传说"][leagueID]
    }

    struct OpponentInfo: Equatable {
        let name: String?
        let leagueID: Int?
        let stars: Int?
    }
    private(set) var opponent: OpponentInfo?
    private(set) var localLeagueID: Int?
    private(set) var localStars: Int?
    private(set) var gameType: Int?
    private(set) var formatType: Int?

    struct MulliganSnapshot: Equatable {
        let cardIDs: [String]
        let done: Bool
    }
    private(set) var mulligan: MulliganSnapshot?

    struct CollectionSummary {
        var owned: [String: Int] = [:]
        var dust = 0
        var gold = 0
    }
    private(set) var collection: CollectionSummary?

    private var mirror: HearthMirror?
    private var mirrorPID: pid_t = 0
    private var pollTimer: Timer?

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "unity.Blizzard Entertainment.Hearthstone"
        }
        guard let app else {
            mirror = nil
            attached = false
            return
        }
        if mirror == nil || mirrorPID != app.processIdentifier {
            // acquireTaskportRight may prompt on first attach; non-blocking retry
            _ = acquireTaskportRight()
            let created = MirrorFaultGuard.protect {
                HearthMirror(pid: app.processIdentifier, blocking: false)
            }
            guard let created else {
                mirror = nil
                attached = false
                return
            }
            mirror = created
            mirrorPID = app.processIdentifier
        }
        guard let mirror else { return }

        let reading = MirrorFaultGuard.protect { () -> LiveReading in
            var reading = LiveReading()
            if self.battleTag == nil { reading.battleTag = mirror.getBattleTag() }
            reading.selectedDeckID = mirror.getSelectedDeck()?.intValue
            if self.ownDecks.isEmpty {
                reading.decks = mirror.getDecks().map { deck in
                    OwnDeck(
                        id: deck.id.intValue,
                        name: deck.name ?? "?",
                        heroCardID: deck.hero ?? "?",
                        formatType: deck.formatType.intValue,
                        cards: deck.cards.map { ($0.cardId, $0.count.intValue) }
                    )
                }
            }
            if let match = mirror.getMatchInfo() {
                reading.opponent = OpponentInfo(
                    name: match.opposingPlayer.name,
                    leagueID: match.opposingPlayer.standardMedalInfo.leagueId.intValue,
                    stars: match.opposingPlayer.standardMedalInfo.stars.intValue
                )
                reading.localLeagueID = match.localPlayer.standardMedalInfo.leagueId.intValue
                reading.localStars = match.localPlayer.standardMedalInfo.stars.intValue
                reading.gameType = match.gameType.intValue
                reading.formatType = match.formatType.intValue
            }
            if let ms = mirror.getMulliganState() {
                reading.mulligan = MulliganSnapshot(
                    cardIDs: ms.mulliganCards.compactMap { $0.cardId },
                    done: !ms.waitingForUserInput
                )
            }
            return reading
        }
        guard let reading else {
            self.mirror = nil
            attached = false
            return
        }
        attached = true
        if battleTag == nil { battleTag = reading.battleTag }
        if let selected = reading.selectedDeckID {
            selectedDeckID = selected
            selectedDeckName = ownDecks.first { $0.id == selected }?.name
        }
        if ownDecks.isEmpty, let decks = reading.decks {
            ownDecks = decks
        }
        if let opponent = reading.opponent {
            self.opponent = opponent
            localLeagueID = reading.localLeagueID
            localStars = reading.localStars
            RankLog.record(leagueID: localLeagueID, stars: localStars)
            gameType = reading.gameType
            formatType = reading.formatType
        } else {
            opponent = nil
            gameType = nil
            formatType = nil
        }
        mulligan = reading.mulligan
    }

    private struct LiveReading {
        var battleTag: String?
        var selectedDeckID: Int?
        var decks: [OwnDeck]?
        var opponent: OpponentInfo?
        var localLeagueID: Int?
        var localStars: Int?
        var gameType: Int?
        var formatType: Int?
        var mulligan: MulliganSnapshot?
    }

    /// The collection is only readable while the in-game collection scene is
    /// loaded; call when the user opens the 收藏 page in the helper.
    func fetchCollectionIfNeeded() {
        guard let mirror else { return }
        if let collection, !collection.owned.isEmpty { return }
        guard let coll = MirrorFaultGuard.protect({ mirror.getCollection() }) else {
            self.mirror = nil
            attached = false
            return
        }
        var summary = CollectionSummary(dust: coll.dust.intValue, gold: coll.gold.intValue)
        for card in coll.cards {
            let id = card.cardId
            summary.owned[id, default: 0] += card.count.intValue
        }
        // An empty read means the collection scene is not loaded. Keep the
        // previous snapshot, and try again the next time the page opens.
        guard !summary.owned.isEmpty else { return }
        collection = summary
    }
}
