import Foundation

/// References the entity a TAG_CHANGE targets; Power.log encodes game-level
/// tags on the symbolic `GameEntity` and player tags on the player's name.
public enum PowerLogEntityRef: Equatable, Hashable, Sendable {
    case id(Int)
    case gameEntity
    case named(String)
}

/// A normalized subset of Power.log packets required for card identity and zone tracking.
public enum PowerLogEvent: Equatable, Sendable {
    case gameCreated
    case playerDeclared(entityID: Int, playerID: Int, accountID: String?)
    /// Mulligan choice blocks carry "Player=<BattleTag>" with entities of
    /// `player=<playerID>` — the log's own BattleTag→player mapping.
    case playerNamed(name: String, playerID: Int)
    /// SHUFFLE_DECK PlayerID=N — after this the client retires the pre-shuffle
    /// deck entities and materializes the deck lazily.
    case deckShuffled(playerID: Int)
    case fullEntity(entityID: Int, cardID: String?)
    case shownEntity(entityID: Int, cardID: String)
    case changedEntity(entityID: Int, cardID: String)
    case tagChanged(entity: PowerLogEntityRef, tag: String, value: String)
    case blockStarted(entityID: Int?, blockType: String?)
}

/// Parses individual Power.log lines without assuming a timestamp or log prefix.
///
/// The parser remembers the entity opened by the most recent FULL_ENTITY /
/// SHOW_ENTITY / CHANGE_ENTITY packet so that the indented `tag=… value=…`
/// rows nested under that packet are attributed to the right entity; those
/// rows carry the initial ZONE/CONTROLLER/CREATOR of every created entity.
public struct PowerLogLineParser: Sendable {
    public private(set) var currentEntityID: Int?
    private var pendingChoicesName: String?

    public init() {}

    public mutating func parse(_ rawLine: String) -> PowerLogEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // PowerTaskList is a lagged replay stream: its tail packets from the
        // previous game arrive AFTER the next game's CREATE_GAME and pollute
        // the fresh state (entity IDs are reused per game), which used to
        // swap the two players. GameState is authoritative and complete for
        // everything this tracker needs.
        if line.contains("PowerTaskList.DebugPrintPower()") { return nil }

        if line.contains("CREATE_GAME") {
            currentEntityID = nil
            return .gameCreated
        }

        // "Player EntityID=2 PlayerID=1 GameAccountId=[hi=… lo=…]" rows inside CREATE_GAME
        if line.contains(" Player EntityID="),
           let entityID = capture("\\bEntityID=(\\d+)", in: line),
           let playerID = capture("\\bPlayerID=(\\d+)", in: line),
           let entityValue = Int(entityID), let playerValue = Int(playerID)
        {
            currentEntityID = nil
            return .playerDeclared(
                entityID: entityValue,
                playerID: playerValue,
                accountID: capture("\\blo=(\\d+)", in: line)
            )
        }

        if line.contains("FULL_ENTITY") {
            guard let entityID = entityID(in: line) else { return nil }
            currentEntityID = entityID
            return .fullEntity(entityID: entityID, cardID: cardID(in: line))
        }

        if line.contains("SHOW_ENTITY") {
            guard let entityID = entityID(in: line), let cardID = cardID(in: line), !cardID.isEmpty else {
                return nil
            }
            currentEntityID = entityID
            return .shownEntity(entityID: entityID, cardID: cardID)
        }

        if line.contains("CHANGE_ENTITY") {
            guard let entityID = entityID(in: line), let cardID = cardID(in: line), !cardID.isEmpty else {
                return nil
            }
            currentEntityID = entityID
            return .changedEntity(entityID: entityID, cardID: cardID)
        }

        if line.contains("TAG_CHANGE") {
            guard let tag = capture("\\btag=([^\\s]+)", in: line),
                  let value = capture("\\bvalue=(.+)$", in: line)?.trimmingCharacters(in: .whitespaces),
                  let ref = entityRef(in: line)
            else {
                return nil
            }
            return .tagChanged(entity: ref, tag: tag, value: value)
        }

        if line.contains("BLOCK_START") {
            return .blockStarted(
                entityID: entityID(in: line),
                blockType: capture("\\bBlockType=([^\\s]+)", in: line)
            )
        }

        if line.contains("SHUFFLE_DECK PlayerID=") {
            if let playerID = capture("PlayerID=(\\d+)", in: line), let id = Int(playerID) {
                return .deckShuffled(playerID: id)
            }
            return nil
        }

        // Mulligan choice blocks: "id=N Player=<tag>" followed by
        // "Entities[0]=[... player=M]" pair a BattleTag with its playerID.
        if line.contains("DebugPrintEntityChoices() - id=") {
            pendingChoicesName = capture("Player=([^\\s]+)", in: line)
            return nil
        }
        if line.contains("DebugPrintEntityChoices() -   Entities[0]=") {
            defer { pendingChoicesName = nil }
            if let name = pendingChoicesName,
               let playerID = capture("player=(\\d+)", in: line), let id = Int(playerID) {
                return .playerNamed(name: name, playerID: id)
            }
            return nil
        }

        // Indented tag row nested under the current FULL/SHOW/CHANGE_ENTITY packet.
        if let tag = capture("\\btag=([^\\s]+)", in: line),
           let value = capture("\\bvalue=(.+)$", in: line)?.trimmingCharacters(in: .whitespaces),
           let entityID = currentEntityID
        {
            return .tagChanged(entity: .id(entityID), tag: tag, value: value)
        }

        return nil
    }

    private func entityRef(in line: String) -> PowerLogEntityRef? {
        if line.contains("Entity=GameEntity") {
            return .gameEntity
        }
        if let id = entityID(in: line) {
            return .id(id)
        }
        if let name = capture("\\bEntity=(\\S+)", in: line), !name.hasPrefix("[") {
            return .named(name)
        }
        return nil
    }

    private func cardID(in line: String) -> String? {
        guard let captured = capture("\\bCardID=([^\\s]*)", in: line), !captured.isEmpty else {
            return nil
        }
        return captured
    }

    private func entityID(in line: String) -> Int? {
        let patterns = [
            "\\bID=(\\d+)",
            "\\bid=(\\d+)",
            "\\bEntity=(\\d+)"
        ]

        for pattern in patterns {
            if let value = capture(pattern, in: line), let entityID = Int(value) {
                return entityID
            }
        }
        return nil
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }
}

public struct ObservedEntity: Equatable, Sendable {
    public let entityID: Int
    public private(set) var cardID: String?
    public private(set) var zone: String?
    public private(set) var controller: Int?
    public private(set) var creatorEntityID: Int?
    public private(set) var cardType: String?
    public private(set) var cost: Int?
    public private(set) var atk: Int?
    public private(set) var health: Int?
    public private(set) var armor: Int?
    public private(set) var damage: Int?
    public private(set) var playstate: String?
    public private(set) var hasEnteredHand = false
    /// Created with its cardID already printed (mechanic shadows and generated
    /// copies) — never a hidden deck copy.
    public private(set) var wasCreatedRevealed = false

    init(entityID: Int, cardID: String? = nil, zone: String? = nil, controller: Int? = nil) {
        self.entityID = entityID
        self.cardID = cardID
        self.zone = zone
        self.controller = controller
    }

    mutating func apply(cardID: String) {
        self.cardID = cardID
    }

    mutating func apply(createdRevealed: Bool) {
        wasCreatedRevealed = createdRevealed
    }

    /// T5 marker: the last cost known while the card was in hand. Re-dealt
    /// replacements keep this tag while their zone stays DECK.
    public private(set) var hasKnownCostInHand = false

    mutating func apply(tag: String, value: String) {
        switch tag {
        case "ZONE":
            zone = value
            if value == "HAND" { hasEnteredHand = true }
        case "CONTROLLER":
            controller = Int(value)
        case "CREATOR", "DISPLAYED_CREATOR":
            creatorEntityID = Int(value)
        case "CARDTYPE":
            cardType = value
        case "TAG_LAST_KNOWN_COST_IN_HAND":
            hasKnownCostInHand = true
        case "COST":
            // keep the first observed cost: it is the card's base cost, while
            // later values may be temporary discounts applied in play
            if cost == nil { cost = Int(value) }
        case "PLAYSTATE":
            playstate = value
        case "ATK":
            atk = Int(value)
        case "HEALTH":
            health = Int(value)
        case "ARMOR":
            armor = Int(value)
        case "DAMAGE":
            damage = Int(value)
        default:
            break
        }
    }
}

/// Reduces normalized packets into the current observed entity state.
public struct PowerLogState: Sendable {
    public private(set) var entities: [Int: ObservedEntity] = [:]
    public private(set) var gameTags: [String: String] = [:]
    public private(set) var namedTags: [String: [String: String]] = [:]

    public init() {}

    public mutating func apply(_ event: PowerLogEvent) {
        switch event {
        case .gameCreated:
            entities.removeAll(keepingCapacity: true)
            gameTags.removeAll(keepingCapacity: true)
            namedTags.removeAll(keepingCapacity: true)
        case .playerDeclared:
            break
        case .playerNamed:
            break
        case .deckShuffled:
            break
        case let .fullEntity(entityID, cardID):
            let isNew = entities[entityID] == nil
            var entity = entities[entityID] ?? ObservedEntity(entityID: entityID)
            if let cardID {
                entity.apply(cardID: cardID)
                if isNew { entity.apply(createdRevealed: true) }
            }
            entities[entityID] = entity
        case let .shownEntity(entityID, cardID), let .changedEntity(entityID, cardID):
            var entity = entities[entityID] ?? ObservedEntity(entityID: entityID)
            entity.apply(cardID: cardID)
            entities[entityID] = entity
        case let .tagChanged(ref, tag, value):
            switch ref {
            case .gameEntity:
                gameTags[tag] = value
            case .named(let name):
                namedTags[name, default: [:]][tag] = value
            case .id(let entityID):
                // The game entity is always ID 1; some clients spell it out as
                // `Entity=GameEntity`, others pass the raw numeric ID.
                if entityID == 1 {
                    gameTags[tag] = value
                } else {
                    var entity = entities[entityID] ?? ObservedEntity(entityID: entityID)
                    entity.apply(tag: tag, value: value)
                    entities[entityID] = entity
                }
            }
        case .blockStarted:
            break
        }
    }
}

/// Reads only appended complete lines. If the game recreates or truncates Power.log, it safely starts over.
public struct PowerLogTailer {
    private let fileURL: URL
    private var parser: PowerLogLineParser
    private var byteOffset: Int = 0
    private var unfinishedLine = ""
    /// Timestamp of the most recently parsed line ("HH:MM:SS.ffffff"), used to
    /// correlate CREATE_GAME with the deck queued in Decks.log.
    public private(set) var lastTimestamp: String?

    public init(fileURL: URL, parser: PowerLogLineParser = PowerLogLineParser()) {
        self.fileURL = fileURL
        self.parser = parser
    }

    public mutating func readNewEvents() throws -> [PowerLogEvent] {
        let data = try Data(contentsOf: fileURL)
        if data.count < byteOffset {
            byteOffset = 0
            unfinishedLine = ""
            parser = PowerLogLineParser()
        }

        let appended = data.dropFirst(byteOffset)
        byteOffset = data.count
        let text = unfinishedLine + String(decoding: appended, as: UTF8.self)
        var fragments = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            fragments.removeLast()
            unfinishedLine = ""
        } else {
            unfinishedLine = fragments.removeLast()
        }

        var events: [PowerLogEvent] = []
        for fragment in fragments {
            if let stamp = Self.timestampPrefix(in: fragment) {
                lastTimestamp = stamp
            }
            if let event = parser.parse(fragment) {
                events.append(event)
            }
        }
        return events
    }

    private static func timestampPrefix(in line: String) -> String? {
        guard let first = line.first, "DIWE".contains(first) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        let candidate = rest.dropFirst().prefix(16) // HH:MM:SS.ffffff
        guard candidate.count == 16, candidate[candidate.index(candidate.startIndex, offsetBy: 8)] == "." else {
            return nil
        }
        return String(candidate)
    }

    public mutating func reset() {
        byteOffset = 0
        unfinishedLine = ""
        parser = PowerLogLineParser()
        lastTimestamp = nil
    }
}
