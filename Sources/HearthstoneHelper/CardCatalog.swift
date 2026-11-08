import Foundation

/// Card metadata from HearthstoneJSON's public per-locale dump, mapping the
/// cardIDs Power.log speaks in to display names, costs and classes.
public struct CardCatalog: Equatable, Sendable {
    public struct CardInfo: Equatable, Sendable {
        public let dbfId: Int?
        public let name: String?
        public let cost: Int?
        public let rarity: String?
        public let race: String?
        public let set: String?
        public let collectible: Bool?
        public let text: String?
        public let cardClass: String?
        public let type: String?
    }

    /// Mechanic tags derived from the localized card text; synergy pairs are
    /// the complementary tag combinations highlighted as combos. Tags without
    /// a synergy pair still serve as filter dimensions.
    public enum CardMechanic: String, CaseIterable, Hashable, Sendable {
        case deathrattle
        case deathrattleTrigger
        case battlecry
        case battlecryRepeat
        case dragon
        case dragonSynergy
        case mech
        case mechSynergy
        case murloc
        case murlocSynergy
        case beast
        case beastSynergy
        case pirate
        case pirateSynergy
        case demon
        case demonSynergy
        case elemental
        case elementalSynergy
        case spellDamage
        case damageSpell
        case discover
        case taunt
        case rush
        case charge
        case divineShield
        case lifesteal
        case poisonous
        case windfury
        case stealth
        case magnetic
        case secret
        case drawCards

        public static let synergyPairs: [(CardMechanic, CardMechanic)] = [
            (.deathrattle, .deathrattleTrigger),
            (.battlecry, .battlecryRepeat),
            (.dragon, .dragonSynergy),
            (.mech, .mechSynergy),
            (.murloc, .murlocSynergy),
            (.beast, .beastSynergy),
            (.pirate, .pirateSynergy),
            (.demon, .demonSynergy),
            (.elemental, .elementalSynergy),
            (.spellDamage, .damageSpell)
        ]

        public static func synergizes(_ lhs: Set<CardMechanic>, _ rhs: Set<CardMechanic>) -> Bool {
            synergyPairs.contains { pair in
                (lhs.contains(pair.0) && rhs.contains(pair.1))
                    || (lhs.contains(pair.1) && rhs.contains(pair.0))
            }
        }
    }

    public let cards: [String: CardInfo]
    /// dbfId → cardID, for decoding deck codes.
    public let dbfIndex: [Int: String]
    /// Approximate Standard-legal sets: CORE plus the six newest expansions
    /// by median dbfId (skin/event/legacy sets excluded).
    public let standardSetKeys: Set<String>

    private static func computeStandardSets(_ cards: [String: CardInfo]) -> Set<String> {
        let excluded: Set<String> = [
            "CORE", "EXPERT1", "LEGACY", "VANILLA", "TIMELESS",
            "HERO_SKINS", "EVENT", "BATTLEGROUNDS", "MERCS",
            "COLLECTIBLE_TITANS_RUN"
        ]
        var bySet: [String: [Int]] = [:]
        for info in cards.values
        where info.collectible == true && info.set != nil && info.dbfId != nil {
            bySet[info.set!, default: []].append(info.dbfId!)
        }
        let expansions = bySet
            .filter { !excluded.contains($0.key) }
            .map { set, dbfs -> (String, Int) in
                let sorted = dbfs.sorted()
                return (set, sorted[sorted.count / 2])
            }
            .sorted { $0.1 > $1.1 }

        var standard = Set(["CORE"])
        standard.formUnion(expansions.prefix(6).map(\.0))
        return standard
    }

    public init(jsonData: Data) throws {
        struct Entry: Decodable {
            let id: String
            let dbfId: Int?
            let name: String?
            let cost: Int?
            let rarity: String?
            let race: String?
            let set: String?
            let collectible: Bool?
            let text: String?
            let cardClass: String?
            let type: String?
        }

        let entries = try JSONDecoder().decode([Entry].self, from: jsonData)
        let pairs = entries.map { entry in
            (
                entry.id,
                CardInfo(
                    dbfId: entry.dbfId,
                    name: entry.name,
                    cost: entry.cost,
                    rarity: entry.rarity,
                    race: entry.race,
                    set: entry.set,
                    collectible: entry.collectible,
                    text: entry.text,
                    cardClass: entry.cardClass,
                    type: entry.type
                )
            )
        }
        let cardMap = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let dbfPairs = pairs.compactMap { id, info -> (Int, String)? in
            guard let dbfId = info.dbfId else { return nil }
            return (dbfId, id)
        }
        self.cards = cardMap
        self.dbfIndex = Dictionary(dbfPairs, uniquingKeysWith: { first, _ in first })
        self.standardSetKeys = Self.computeStandardSets(cardMap)
    }

    public init(cards: [String: CardInfo]) {
        self.cards = cards
        self.dbfIndex = Dictionary(
            cards.compactMap { cardID, info in info.dbfId.map { ($0, cardID) } },
            uniquingKeysWith: { first, _ in first }
        )
        self.standardSetKeys = Self.computeStandardSets(cards)
    }

    public func cardID(forDbfID dbfID: Int) -> String? {
        dbfIndex[dbfID]
    }

    public func info(for cardID: String) -> CardInfo? {
        cards[cardID]
    }

    public func displayName(for cardID: String) -> String {
        cards[cardID]?.name ?? cardID
    }

    public func cost(for cardID: String) -> Int? {
        cards[cardID]?.cost
    }

    /// Rarity key as printed by HearthstoneJSON (COMMON/RARE/EPIC/LEGENDARY…).
    public func rarity(for cardID: String) -> String? {
        cards[cardID]?.rarity
    }

    /// Mechanic tags parsed from the localized card text (and race for dragons).
    public func mechanics(for cardID: String) -> Set<CardMechanic> {
        guard let info = cards[cardID] else { return [] }
        var tags: Set<CardMechanic> = []
        let text = info.text ?? ""

        // base vs amplifier: a card's own 亡语/战吼 uses the "亡语：/战吼：" form;
        // amplifier texts (触发…亡语 / 战吼…触发两次) must not also count as base
        let ownsDeathrattle = text.contains("亡语：")
        if ownsDeathrattle { tags.insert(.deathrattle) }
        if !ownsDeathrattle, text.contains("触发"), text.contains("亡语") {
            tags.insert(.deathrattleTrigger)
        }
        let ownsBattlecry = text.contains("战吼：")
        if ownsBattlecry { tags.insert(.battlecry) }
        if text.contains("战吼"), text.contains("重复") || text.contains("两次") || text.contains("再次") {
            tags.insert(.battlecryRepeat)
        }
        // tribes: race grants the base tag, text mentions grant the synergy tag
        let tribes: [(race: String, cn: String, base: CardMechanic, synergy: CardMechanic)] = [
            ("DRAGON", "龙", .dragon, .dragonSynergy),
            ("MECHANICAL", "机械", .mech, .mechSynergy),
            ("MURLOC", "鱼人", .murloc, .murlocSynergy),
            ("BEAST", "野兽", .beast, .beastSynergy),
            ("PIRATE", "海盗", .pirate, .pirateSynergy),
            ("DEMON", "恶魔", .demon, .demonSynergy),
            ("ELEMENTAL", "元素", .elemental, .elementalSynergy)
        ]
        for tribe in tribes {
            if info.race == tribe.race {
                tags.insert(tribe.base)
            } else if text.contains(tribe.cn) {
                tags.insert(tribe.synergy)
            }
        }
        if text.contains("法术伤害") { tags.insert(.spellDamage) }
        if info.type == "SPELL", text.contains("造成"), text.contains("伤害") {
            tags.insert(.damageSpell)
        }
        if text.contains("发现") { tags.insert(.discover) }
        if text.contains("嘲讽") { tags.insert(.taunt) }
        if text.contains("突袭") { tags.insert(.rush) }
        if text.contains("冲锋") { tags.insert(.charge) }
        if text.contains("圣盾") { tags.insert(.divineShield) }
        if text.contains("吸血") { tags.insert(.lifesteal) }
        if text.contains("剧毒") { tags.insert(.poisonous) }
        if text.contains("风怒") { tags.insert(.windfury) }
        if text.contains("潜行") { tags.insert(.stealth) }
        if text.contains("磁力") { tags.insert(.magnetic) }
        if text.contains("奥秘") { tags.insert(.secret) }
        if text.contains("抽"), text.contains("牌") { tags.insert(.drawCards) }

        return tags
    }

    /// Whether two cards form a known synergy pair (combo highlight).
    public func hasCombo(_ cardID: String, with other: String) -> Bool {
        CardMechanic.synergizes(mechanics(for: cardID), mechanics(for: other))
    }

    // MARK: - Display-name dimensions (shared by deck view & collection browser)

    public static let rarityDisplayNames: [String: String] = [
        "COMMON": "普通", "RARE": "稀有", "EPIC": "史诗", "LEGENDARY": "传说"
    ]

    public static let mechanicDisplayNames: [String: String] = [
        "deathrattle": "亡语", "deathrattleTrigger": "亡语触发",
        "battlecry": "战吼", "battlecryRepeat": "战吼重复",
        "dragon": "龙", "dragonSynergy": "龙联动",
        "mech": "机械", "mechSynergy": "机械联动",
        "murloc": "鱼人", "murlocSynergy": "鱼人联动",
        "beast": "野兽", "beastSynergy": "野兽联动",
        "pirate": "海盗", "pirateSynergy": "海盗联动",
        "demon": "恶魔", "demonSynergy": "恶魔联动",
        "elemental": "元素", "elementalSynergy": "元素联动",
        "spellDamage": "法术伤害", "damageSpell": "伤害法术",
        "discover": "发现",
        "taunt": "嘲讽", "rush": "突袭", "charge": "冲锋",
        "divineShield": "圣盾", "lifesteal": "吸血", "poisonous": "剧毒",
        "windfury": "风怒", "stealth": "潜行", "magnetic": "磁力",
        "secret": "奥秘", "drawCards": "过牌"
    ]

    public static let raceDisplayNames: [String: String] = [
        "BEAST": "野兽", "DEMON": "恶魔", "MURLOC": "鱼人", "ELEMENTAL": "元素",
        "MECHANICAL": "机械", "PIRATE": "海盗", "TOTEM": "图腾", "QUILBOAR": "野猪人",
        "DRAGON": "龙"
    ]

    public static let classDisplayNames: [String: String] = [
        "MAGE": "法师", "HUNTER": "猎人", "WARRIOR": "战士", "PRIEST": "牧师",
        "WARLOCK": "术士", "ROGUE": "潜行者", "SHAMAN": "萨满祭司",
        "PALADIN": "圣骑士", "DRUID": "德鲁伊", "DEATHKNIGHT": "死亡骑士",
        "DEMONHUNTER": "恶魔猎手", "NEUTRAL": "中立"
    ]

    public func typeLabel(for cardID: String) -> String {
        guard let info = cards[cardID] else { return "其他" }
        let text = info.text ?? ""
        if text.contains("任务：") || text.contains("支线任务") { return "任务" }
        switch info.type {
        case "MINION": return "随从"
        case "SPELL": return "法术"
        case "WEAPON": return "武器"
        case "HERO": return "英雄"
        case "LOCATION": return "地标"
        default: return "其他"
        }
    }

    public func rarityLabel(for cardID: String) -> String {
        Self.rarityDisplayNames[rarity(for: cardID) ?? "COMMON"] ?? "其他"
    }

    public func mechanicLabels(for cardID: String) -> Set<String> {
        Set(mechanics(for: cardID).compactMap { Self.mechanicDisplayNames[$0.rawValue] })
    }

    public func raceLabel(for cardID: String) -> String? {
        guard let race = cards[cardID]?.race else { return nil }
        return Self.raceDisplayNames[race] ?? Self.raceDisplayNames[race.uppercased()]
    }

    public func classLabel(for cardID: String) -> String {
        guard let cardClass = cards[cardID]?.cardClass else { return "中立" }
        return Self.classDisplayNames[cardClass] ?? "中立"
    }

    public func costBucket(for cardID: String) -> Int {
        min(cost(for: cardID) ?? 0, 7)
    }

    public func isStandard(_ cardID: String) -> Bool {
        guard let set = cards[cardID]?.set else { return false }
        return standardSetKeys.contains(set)
    }

    /// All collectible cards, cost-then-name ordered, for the collection browser.
    public var collectibleCardIDs: [String] {
        cards
            .filter { $0.value.collectible == true }
            .map(\.key)
            .sorted { lhs, rhs in
                let l = (cost(for: lhs) ?? 0, displayName(for: lhs))
                let r = (cost(for: rhs) ?? 0, displayName(for: rhs))
                return l < r
            }
    }

    // MARK: - Combat helpers

    /// All secrets of a given class (by Chinese class label), cost-ordered.
    public func secretCardIDs(classLabel label: String) -> [String] {
        cards
            .filter { cardID, info in
                info.collectible == true
                    && info.type == "SPELL"
                    && (info.text ?? "").contains("奥秘")
                    && label == (Self.classDisplayNames[info.cardClass ?? ""] ?? "中立")
            }
            .map(\.key)
            .sorted { (cost(for: $0) ?? 0, $0) < (cost(for: $1) ?? 0, $1) }
    }

    /// A spell whose text deals direct damage — flagged 💥 in hand for lethal
    /// eyeballing (values aren't parsed; the player adds them up).
    public func isDirectDamage(_ cardID: String) -> Bool {
        guard let info = cards[cardID], info.type == "SPELL" else { return false }
        let text = info.text ?? ""
        return text.contains("造成") && text.contains("伤害")
    }

    /// Guaranteed hero-power damage by class (Chinese label); 0 when variable
    /// or non-damaging.
    public static func heroPowerDamage(classLabel label: String) -> Int {
        switch label {
        case "猎人": return 2
        case "法师", "潜行者", "德鲁伊", "恶魔猎手": return 1
        default: return 0
        }
    }

    private static let classNames: [String: String] = [
        "MAGE": "法师",
        "HUNTER": "猎人",
        "WARRIOR": "战士",
        "PRIEST": "牧师",
        "WARLOCK": "术士",
        "ROGUE": "潜行者",
        "SHAMAN": "萨满祭司",
        "PALADIN": "圣骑士",
        "DRUID": "德鲁伊",
        "DEATHKNIGHT": "死亡骑士",
        "DEMONHUNTER": "恶魔猎手",
        "NEUTRAL": "中立"
    ]

    /// The opponent class shown in the UI comes from their hero card's class;
    /// non-hero cards are rejected so a spell cardID can never pose as a class.
    public func classDisplayName(forHeroCardID cardID: String) -> String? {
        guard let info = cards[cardID], info.type == "HERO", let cardClass = info.cardClass else {
            return nil
        }
        return Self.classNames[cardClass]
    }

    /// Localizes a raw (cardID-based) match record for display. Unknown IDs are
    /// left as-is so no information is lost when the catalog runs behind a patch.
    public func apply(to record: MatchRecord) -> MatchRecord {
        func map(_ card: TrackedCard) -> TrackedCard {
            TrackedCard(
                id: card.id,
                name: displayName(for: card.name),
                cardID: card.cardID ?? card.name,
                cost: cost(for: card.name) ?? card.cost,
                copies: card.copies,
                origin: card.origin,
                playedTurn: card.playedTurn,
                sourceTrail: card.sourceTrail.map { displayName(for: $0) },
                isBoardOnly: card.isBoardOnly
            )
        }

        return MatchRecord(
            id: record.id,
            playerDeckName: record.playerDeckName,
            playerDeckID: record.playerDeckID,
            opponentClass: classDisplayName(forHeroCardID: record.opponentClass) ?? record.opponentClass,
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
                playerHandCards: record.playerHandCards.map(map),
            playerRemainingCards: record.playerRemainingCards.map(map),
            playerShuffledCards: record.playerShuffledCards.map(map),
            playerPlayedCards: record.playerPlayedCards.map(map),
            opponentCards: record.opponentCards.map(map),
            candidate: DeckCandidate(
                expectedCardCount: record.candidate.expectedCardCount,
                confirmedOriginalCards: record.candidate.confirmedOriginalCards.map(map),
                integrity: record.candidate.integrity
            )
        )
    }
}
