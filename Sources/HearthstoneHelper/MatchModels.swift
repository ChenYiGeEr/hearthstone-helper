import Foundation

public enum CardOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case original
    case generated
    case unknown

    public var title: String {
        switch self {
        case .original: "确认原始牌"
        case .generated: "确认衍生牌"
        case .unknown: "来源未知"
        }
    }
}

public enum MatchIntegrity: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case logIssue

    public var title: String {
        switch self {
        case .complete: "完整记录"
        case .partial: "部分记录"
        case .logIssue: "日志异常"
        }
    }

    public var detail: String {
        switch self {
        case .complete: "本局日志从开局持续记录，可用于校验候选卡组。"
        case .partial: "应用在对局中途开始记录；本局不会导出确定卡组代码。"
        case .logIssue: "日志事件不完整；请检查日志配置后再进行下一局。"
        }
    }
}

public struct TrackedCard: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    /// The raw Power.log cardID this row came from; survives display-name
    /// localization so card art can still be resolved.
    public let cardID: String?

    /// Stable SwiftUI identity across snapshots: the UUID `id` is minted fresh
    /// on every snapshot, so lists keyed on it rebuild wholesale and can never
    /// animate insertions/removals. Lists aggregate by cardID, making it the
    /// natural stable key.
    public var rowKey: String { cardID ?? name }
    public let cost: Int
    public let copies: Int
    public let origin: CardOrigin
    public let playedTurn: Int
    public let sourceTrail: [String]
    public let isBoardOnly: Bool
    /// Where the card physically sits right now (DECK/HAND/PLAY/…), for
    /// Firestone-style zone grouping; nil for deck-list projections.
    public let currentZone: String?

    public init(
        id: UUID = UUID(),
        name: String,
        cardID: String? = nil,
        cost: Int,
        copies: Int = 1,
        origin: CardOrigin,
        playedTurn: Int,
        sourceTrail: [String] = [],
        isBoardOnly: Bool = false,
        currentZone: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cardID = cardID
        self.cost = cost
        self.copies = copies
        self.origin = origin
        self.playedTurn = playedTurn
        self.sourceTrail = sourceTrail
        self.isBoardOnly = isBoardOnly
        self.currentZone = currentZone
    }
}

public struct DeckCandidate: Hashable, Codable, Sendable {
    public let expectedCardCount: Int
    public let confirmedOriginalCards: [TrackedCard]
    public let integrity: MatchIntegrity

    public init(expectedCardCount: Int, confirmedOriginalCards: [TrackedCard], integrity: MatchIntegrity) {
        precondition([30, 40].contains(expectedCardCount), "Constructed decks must contain 30 or 40 cards.")
        self.expectedCardCount = expectedCardCount
        self.confirmedOriginalCards = confirmedOriginalCards
        self.integrity = integrity
    }

    public var confirmedCardCount: Int {
        confirmedOriginalCards.reduce(into: 0) { $0 += $1.copies }
    }

    public var isExportable: Bool {
        integrity == .complete && confirmedCardCount == expectedCardCount
    }

    public var statusText: String {
        if isExportable {
            "已还原 \(expectedCardCount) 张原始牌，可导出卡组代码"
        } else if integrity != .complete {
            "\(integrity.title)：不可导出确定卡组代码"
        } else {
            "已确认 \(confirmedCardCount) / \(expectedCardCount) 张，保留为候选草稿"
        }
    }
}

/// Match outcome as reported by the client (PLAYSTATE) for the friendly player.
public enum MatchOutcome: String, Codable, Hashable, Sendable {
    case win
    case loss
    case tie
}

/// Live per-side board statistics — all publicly visible information.
public struct SideStats: Codable, Hashable, Sendable {
    public let handCount: Int
    public let deckCount: Int
    public let boardATK: Int
    public let weaponATK: Int
    public let secrets: Int
    public let currentHealth: Int

    public init(
        handCount: Int,
        deckCount: Int,
        boardATK: Int,
        weaponATK: Int = 0,
        secrets: Int = 0,
        currentHealth: Int
    ) {
        self.handCount = handCount
        self.deckCount = deckCount
        self.boardATK = boardATK
        self.weaponATK = weaponATK
        self.secrets = secrets
        self.currentHealth = currentHealth
    }
}

/// One turn of the post-game timeline: what each side played that turn.
public struct TurnLog: Codable, Hashable, Sendable {
    public let turn: Int
    public let friendlyPlays: [TrackedCard]
    public let opponentPlays: [TrackedCard]

    public init(turn: Int, friendlyPlays: [TrackedCard], opponentPlays: [TrackedCard]) {
        self.turn = turn
        self.friendlyPlays = friendlyPlays
        self.opponentPlays = opponentPlays
    }
}

public struct MatchRecord: Hashable, Codable, Sendable {
    public let id: UUID
    public let playerDeckName: String
    public let playerDeckID: Int?
    public let opponentClass: String
    public let startedAt: Date
    public let integrity: MatchIntegrity
    public let result: MatchOutcome?
    public let friendlyStats: SideStats?
    public let opponentStats: SideStats?
    public let turnStartedAt: Date?
    /// True while the opponent holds the turn (CURRENT_PLAYER), false while the
    /// friendly player does; nil before the first turn begins.
    public let currentActorIsOpponent: Bool?
    public let opponentAccountID: String?
    public let revealedSecrets: [String]
    public let mulliganKept: [String]
    public let mulliganDiscarded: [String]
    public let turns: [TurnLog]
    public let playerHandCards: [TrackedCard]
    public let playerRemainingCards: [TrackedCard]
    public let playerShuffledCards: [TrackedCard]
    public let playerPlayedCards: [TrackedCard]
    public let opponentCards: [TrackedCard]
    public let candidate: DeckCandidate

    public init(
        id: UUID = UUID(),
        playerDeckName: String,
        playerDeckID: Int? = nil,
        opponentClass: String,
        startedAt: Date,
        integrity: MatchIntegrity,
        result: MatchOutcome? = nil,
        friendlyStats: SideStats? = nil,
        opponentStats: SideStats? = nil,
        turnStartedAt: Date? = nil,
        currentActorIsOpponent: Bool? = nil,
        opponentAccountID: String? = nil,
        revealedSecrets: [String] = [],
        mulliganKept: [String] = [],
        mulliganDiscarded: [String] = [],
        turns: [TurnLog] = [],
        playerHandCards: [TrackedCard] = [],
        playerRemainingCards: [TrackedCard],
        playerShuffledCards: [TrackedCard],
        playerPlayedCards: [TrackedCard],
        opponentCards: [TrackedCard],
        candidate: DeckCandidate
    ) {
        self.id = id
        self.playerDeckName = playerDeckName
        self.playerDeckID = playerDeckID
        self.opponentClass = opponentClass
        self.startedAt = startedAt
        self.integrity = integrity
        self.result = result
        self.friendlyStats = friendlyStats
        self.opponentStats = opponentStats
        self.turnStartedAt = turnStartedAt
        self.currentActorIsOpponent = currentActorIsOpponent
        self.opponentAccountID = opponentAccountID
        self.revealedSecrets = revealedSecrets
        self.mulliganKept = mulliganKept
        self.mulliganDiscarded = mulliganDiscarded
        self.turns = turns
        self.playerHandCards = playerHandCards
        self.playerRemainingCards = playerRemainingCards
        self.playerShuffledCards = playerShuffledCards
        self.playerPlayedCards = playerPlayedCards
        self.opponentCards = opponentCards
        self.candidate = candidate
    }

    public func opponentCards(for origin: CardOrigin) -> [TrackedCard] {
        opponentCards
            .filter { $0.origin == origin && !$0.isBoardOnly }
            .sorted { lhs, rhs in
                lhs.playedTurn == rhs.playedTurn ? lhs.cost < rhs.cost : lhs.playedTurn < rhs.playedTurn
            }
    }
}

extension MatchRecord {
    public static let preview = MatchRecord(
        playerDeckName: "彩虹死亡骑士",
        opponentClass: "法师",
        startedAt: .now,
        integrity: .complete,
        playerRemainingCards: [
            TrackedCard(name: "寒冬号角", cost: 2, copies: 1, origin: .original, playedTurn: 0),
            TrackedCard(name: "矿坑老板雷斯卡", cost: 5, copies: 1, origin: .original, playedTurn: 0),
            TrackedCard(name: "尸体新星", cost: 7, copies: 2, origin: .original, playedTurn: 0)
        ],
        playerShuffledCards: [
            TrackedCard(name: "死灵殡葬师", cost: 3, origin: .generated, playedTurn: 4, sourceTrail: ["矿坑老板雷斯卡"])
        ],
        playerPlayedCards: [
            TrackedCard(name: "彩虹裁缝", cost: 3, origin: .original, playedTurn: 3)
        ],
        opponentCards: [
            TrackedCard(name: "大法师安东尼达斯", cost: 7, origin: .original, playedTurn: 8),
            TrackedCard(name: "火球术", cost: 4, origin: .generated, playedTurn: 8, sourceTrail: ["大法师安东尼达斯"]),
            TrackedCard(name: "奥术智慧", cost: 3, origin: .unknown, playedTurn: 5),
            TrackedCard(name: "水元素", cost: 4, origin: .generated, playedTurn: 6, sourceTrail: ["召唤：深海融合怪"], isBoardOnly: true)
        ],
        candidate: DeckCandidate(
            expectedCardCount: 30,
            confirmedOriginalCards: [
                TrackedCard(name: "大法师安东尼达斯", cost: 7, copies: 1, origin: .original, playedTurn: 8)
            ],
            integrity: .complete
        )
    )
}
