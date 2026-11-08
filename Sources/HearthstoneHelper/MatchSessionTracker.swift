import Foundation

/// Reduces the normalized Power.log stream into the observable match state the UI renders.
///
/// Honesty rules baked into this reducer (per the confirmed design):
/// - Opponent cards are recorded only when the client reveals them (SHOW_ENTITY / CHANGE_ENTITY);
///   hidden entities never leak into the record even though Power.log contains them.
/// - A match recorded without its CREATE_GAME is marked partial and every reveal inside it
///   keeps origin `.unknown` — incomplete evidence must never look like a confirmed deck.
/// - Transforms keep the origin of the entity they re-identify; cards created mid-game are
///   always generated, never original, regardless of sharing a name with a deck card.
public struct MatchSessionTracker: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        case partialRecording
    }

    public private(set) var state = PowerLogState()
    public private(set) var phase: Phase = .idle
    public private(set) var startedAt: Date?
    /// Stable identity for the current game: assigned once per match (not per
    /// snapshot) so self-heal replays of the same game dedup in history.
    public private(set) var matchID = UUID()
    public private(set) var currentTurn = 0
    public private(set) var isMatchOver = false
    /// True between BEGIN_MULLIGAN and MAIN_READY: replaced cards travel
    /// through SETASIDE in this window and must not count as plays.
    public private(set) var mulliganActive = false
    /// The deal snapshot held for the whole mulligan window: the T5 client
    /// deals at submit-time and shuttles cards through intermediate zones,
    /// so live counts during the window are meaningless. The frozen snapshot
    /// matches what the game UI shows (dealt hand / rest of deck).
    private var mulliganFreeze: MatchRecord?
    var turnStartedAt: Date?

    private var initialCardEntityIDs: Set<Int> = []
    private var initialBatchOpen = false
    private var controllersResolved = false
    private var friendlyController: Int?
    private var opponentController: Int?
    private var opponentDeckSize: Int?
    private var opponentReveals: [OpponentReveal] = []
    private var revealedEntityIDs: Set<Int> = []
    // Reveals seen before either controller was identifiable; replayed once
    // player identification succeeds so a mid-game join loses no cards.
    private var pendingRevealIDs: [Int] = []

    private var friendlyPlays: [FriendlyPlay] = []
    private var friendlyPlayedEntityIDs: Set<Int> = []
    private var friendlyDeckSize: Int?
    /// PlayerEntity rows inside CREATE_GAME: playerID → the entity that carries
    /// that player's PLAYSTATE (WON/LOST) at game end.
    private var playerEntityByPlayerID: [Int: Int] = [:]
    /// The exact deck list of the queued deck (cardID × count), injected from
    /// the Decks.log code; when present, "remaining deck" is deck-view.
    private var deckListCards: [(cardID: String, count: Int)] = []
    private var currentActorController: Int?
    private var playerAccountByPlayerID: [Int: String] = [:]
    /// BattleTag → player entity (2/3). The client prints final PLAYSTATE
    /// tags with named references only; the two log streams announce both
    /// players in the same order at game start (numeric in GameState,
    /// BattleTag in PowerTaskList), which gives the pairing.
    /// BattleTag → playerID, from the mulligan choice blocks (GameState).
    private var playerNameByPlayerID: [Int: String] = [:]
    /// Entity IDs are assigned in creation order; after the friendly
    /// SHUFFLE_DECK only entities at or above this floor are live bookkeeping
    /// (the pre-shuffle deck entities are retired into SETASIDE by the client).
    private var postShuffleEntityFloor: Int?
    /// Secrets the opponent actually triggered this game (revealed cardIDs).
    private var revealedSecretIDs: [String] = []
    private var mulliganKept: [String] = []
    private var mulliganDiscarded: [String] = []

    /// A reveal is stored as an entity reference, not a frozen card: whether the card
    /// is board-only can only be decided from the entity's final zone history.
    private struct OpponentReveal {
        let entityID: Int
        let name: String
        let origin: CardOrigin
        let firstSeenTurn: Int
        let sourceTrail: [String]
        var copies: Int
    }

    private struct FriendlyPlay {
        let entityID: Int
        let name: String
        let cost: Int
        let origin: CardOrigin
        let turn: Int
        let sourceTrail: [String]
        var copies: Int
    }

    public init() {}

    /// Injects the queued deck's exact card list (resolved from its deck code).
    public mutating func setDeckList(_ cards: [(cardID: String, count: Int)]) {
        deckListCards = cards
    }

    public mutating func apply(_ event: PowerLogEvent) {
        if case .gameCreated = event {
            resetForNewMatch(partial: false)
            state.apply(event)
            return
        }

        markGameInProgressIfNeeded(for: event)
        state.apply(event)
        let controllersNewlyResolved = resolveControllersIfPossible()
        if controllersNewlyResolved {
            for entityID in pendingRevealIDs {
                recordRevealIfOpponent(entityID: entityID)
            }
            pendingRevealIDs.removeAll()
        }

        switch event {
        case .gameCreated:
            break

        case let .playerDeclared(entityID, playerID, accountID):
            playerEntityByPlayerID[playerID] = entityID
            if let accountID {
                playerAccountByPlayerID[playerID] = accountID
            }

        case let .playerNamed(name, playerID):
            playerNameByPlayerID[playerID] = name

        case let .deckShuffled(playerID):
            if playerID == friendlyController {
                postShuffleEntityFloor = (state.entities.keys.max() ?? 0) + 1
                // the deck is final here: replacements are in hand and the
                // retired pre-shuffle entities are excluded by the floor —
                // exactly the state the game UI shows during the rest of the
                // mulligan window
                if mulliganActive, mulliganFreeze == nil {
                    mulliganFreeze = computeSnapshot()
                }
            }

        case .fullEntity(let entityID, _):
            if initialBatchOpen {
                initialCardEntityIDs.insert(entityID)
            }

        case .shownEntity, .changedEntity:
            switch event {
            case let .shownEntity(entityID, _), let .changedEntity(entityID, _):
                recordRevealIfOpponent(entityID: entityID)
            default:
                break
            }

        case let .tagChanged(ref, tag, value):
            // Game-level tags arrive either as `Entity=GameEntity` or the raw
            // entity ID 1 depending on client build; both mean the game entity.
            let isGameEntity: Bool
            switch ref {
            case .gameEntity:
                isGameEntity = true
            case .id(let entityID):
                isGameEntity = entityID == 1
            case .named:
                isGameEntity = false
            }

            if isGameEntity {
                switch tag {
                case "TURN":
                    // GameState and PowerTaskList replay the turn stream with
                    // interleaved values; only forward progress is real progress.
                    if let turn = Int(value), turn > currentTurn {
                        currentTurn = turn
                        turnStartedAt = .now
                    }
                    if initialBatchOpen { closeInitialBatch() }
                case "STATE" where value == "COMPLETE":
                    isMatchOver = true
                case "STEP" where value == "BEGIN_MULLIGAN":
                    mulliganActive = true
                case "STEP" where value == "MAIN_READY" || value == "MAIN_START":
                    mulliganActive = false
                    mulliganFreeze = nil
                default:
                    break
                }
            }

            // any card leaving the friendly hand has been played — instant
            // spells jump straight to SETASIDE/GRAVEYARD without a PLAY stop
            if tag == "ZONE", case .id(let entityID) = ref,
               ["PLAY", "SETASIDE", "GRAVEYARD", "SECRET", "REMOVEDFROMGAME"].contains(value) {
                recordFriendlyPlayIfApplicable(entityID: entityID)
            }

            if tag == "CURRENT_PLAYER", let playerID = Int(value) {
                currentActorController = playerID > 0 ? playerID : nil
            }



        case .blockStarted:
            break
        }
    }

    /// The friendly player's PLAYSTATE translated into an outcome; nil while
    /// the game is still running (PLAYING) or the state was never observed.
    private var friendlyOutcome: MatchOutcome? {
        guard let friendly = friendlyController else { return nil }

        // primary: numeric PLAYSTATE on the player entity (PLAYING while the
        // game runs — a nil outcome must fall through to the named fallback)
        if
            let entityID = playerEntityByPlayerID[friendly],
            let playstate = state.entities[entityID]?.playstate,
            let outcome = Self.outcome(for: playstate)
        {
            return outcome
        }

        // fallback: this client announces results under BattleTags only;
        // resolve the friendly tag via the mulligan choice blocks
        if
            let name = playerNameByPlayerID[friendly],
            let playstate = state.namedTags[name]?["PLAYSTATE"]
        {
            return Self.outcome(for: playstate)
        }
        return nil
    }

    private static func outcome(for playstate: String) -> MatchOutcome? {
        switch playstate {
        case "WON":
            return .win
        case "LOST", "CONCEDED", "QUIT":
            return .loss
        case "TIED":
            return .tie
        default:
            return nil
        }
    }

    /// The observable match record; nil while no game activity has been seen.
    /// During the mulligan window the frozen deal snapshot is served.
    public mutating func snapshot() -> MatchRecord? {
        if mulliganActive {
            return mulliganFreeze ?? computeSnapshot()
        }
        return computeSnapshot()
    }

    private func computeSnapshot() -> MatchRecord? {
        guard phase != .idle else { return nil }
        let integrity: MatchIntegrity = phase == .partialRecording ? .partial : .complete
        // Constructed decks are 30 or 40 cards; anything else means the deck size
        // was never observed confidently, so fall back to 30 and stay a draft.
        let expectedCardCount = [30, 40].contains(opponentDeckSize ?? 0) ? opponentDeckSize! : 30

        let cards = opponentReveals.map { reveal in
            let entity = state.entities[reveal.entityID]
            return TrackedCard(
                name: reveal.name,
                cardID: reveal.name,
                cost: entity?.cost ?? 0,
                copies: reveal.copies,
                origin: reveal.origin,
                playedTurn: reveal.firstSeenTurn,
                sourceTrail: resolvedTrail(of: reveal.entityID),
                isBoardOnly: !(entity?.hasEnteredHand ?? false) && entity?.zone == "PLAY",
                currentZone: entity?.zone
            )
        }

        // The starting hero is the lowest-entityID hero the opponent controls;
        // later hero swaps must not rewrite the class of the deck being recorded.
        let opponentHero = state.entities.values
            .filter { $0.controller == opponentController && $0.cardType == "HERO" && $0.cardID != nil }
            .min(by: { $0.entityID < $1.entityID })?
            .cardID

        let playedCards = friendlyPlays.map { play in
            TrackedCard(
                name: play.name,
                cardID: play.name,
                cost: play.cost,
                copies: play.copies,
                origin: play.origin,
                playedTurn: play.turn,
                sourceTrail: resolvedTrail(of: play.entityID)
            )
        }

        return MatchRecord(
            id: matchID,
            playerDeckName: friendlyDeckSize.map { "己方卡组（\($0) 张）" } ?? "己方卡组",
            opponentClass: opponentHero ?? "未知职业",
            startedAt: startedAt ?? .now,
            integrity: integrity,
            result: friendlyOutcome,
            friendlyStats: sideStats(controller: friendlyController),
            opponentStats: sideStats(controller: opponentController),
            turnStartedAt: turnStartedAt,
            currentActorIsOpponent: currentActorController.flatMap { actor in
                opponentController.map { actor == $0 }
            },
            opponentAccountID: opponentController.flatMap { playerAccountByPlayerID[$0] },
            revealedSecrets: revealedSecretIDs,
            mulliganKept: mulliganKept,
            mulliganDiscarded: mulliganDiscarded,
            turns: turnTimeline(),
            playerHandCards: friendlyHandCards(),
            playerRemainingCards: remainingFriendlyDeckCards(),
            playerShuffledCards: friendlyShuffledCards(),
            playerPlayedCards: playedCards,
            opponentCards: cards,
            candidate: DeckCandidate(
                expectedCardCount: expectedCardCount,
                confirmedOriginalCards: cards.filter { $0.origin == .original && !$0.isBoardOnly },
                integrity: integrity
            )
        )
    }

    // MARK: - Lifecycle

    private mutating func resetForNewMatch(partial: Bool) {
        state = PowerLogState()
        initialCardEntityIDs = []
        initialBatchOpen = !partial
        controllersResolved = false
        friendlyController = nil
        opponentController = nil
        opponentDeckSize = nil
        opponentReveals = []
        revealedEntityIDs = []
        pendingRevealIDs = []
        friendlyPlays = []
        friendlyPlayedEntityIDs = []
        friendlyDeckSize = nil
        playerEntityByPlayerID = [:]
        playerAccountByPlayerID = [:]
        playerNameByPlayerID = [:]
        postShuffleEntityFloor = nil
        deckListCards = []
        currentActorController = nil
        revealedSecretIDs = []
        mulliganKept = []
        mulliganDiscarded = []
        currentTurn = 0
        isMatchOver = false
        mulliganActive = false
        mulliganFreeze = nil
        turnStartedAt = nil
        startedAt = .now
        matchID = UUID()
        phase = partial ? .partialRecording : .recording
    }

    /// Any gameplay packet arriving without CREATE_GAME means the app joined a game
    /// already in progress — keep observing, but flag the whole match as partial.
    private mutating func markGameInProgressIfNeeded(for event: PowerLogEvent) {
        guard phase == .idle, isGameplayEvidence(event) else { return }
        resetForNewMatch(partial: true)
    }

    private func isGameplayEvidence(_ event: PowerLogEvent) -> Bool {
        switch event {
        case .gameCreated, .playerDeclared, .playerNamed, .deckShuffled, .blockStarted:
            return false
        case .fullEntity, .shownEntity, .changedEntity:
            return true
        case .tagChanged(_, let tag, _):
            return ["ZONE", "TURN", "STEP", "CONTROLLER"].contains(tag)
        }
    }

    private mutating func closeInitialBatch() {
        initialBatchOpen = false
        resolveControllersIfPossible()
        if let opponent = opponentController {
            opponentDeckSize = state.entities.values.count { entity in
                entity.controller == opponent
                    && entity.cardID == nil
                    && (entity.zone == "DECK" || entity.zone == "HAND")
            }
        }
        if let friendly = friendlyController {
            friendlyDeckSize = state.entities.values.count { entity in
                entity.controller == friendly
                    && entity.cardID != nil
                    && entity.cardID != "GAME_005"
                    && (entity.zone == "DECK" || entity.zone == "HAND")
            }
            // mulligan: cards dealt into the friendly hand at the start;
            // those sent back to DECK before turn 1 are the discarded ones
            let openingHand = state.entities.values.filter {
                $0.controller == friendly && $0.cardID != nil && $0.hasEnteredHand
                    && initialCardEntityIDs.contains($0.entityID)
            }
            mulliganKept = openingHand.filter { $0.zone == "HAND" }.compactMap(\.cardID)
            mulliganDiscarded = openingHand.filter { $0.zone == "DECK" }.compactMap(\.cardID)
        }
    }

    /// Post-game timeline: per-turn plays for both sides.
    private func turnTimeline() -> [TurnLog] {
        let lastFriendly = friendlyPlays.map(\.turn).max() ?? 0
        let lastOpponent = opponentReveals.map(\.firstSeenTurn).max() ?? 0
        let maxTurn = max(lastFriendly, lastOpponent)
        guard maxTurn > 0 else { return [] }

        return (1...maxTurn).map { turn in
            TurnLog(
                turn: turn,
                friendlyPlays: friendlyPlays
                    .filter { $0.turn == turn }
                    .map {
                        TrackedCard(
                            name: $0.name, cardID: $0.name, cost: $0.cost,
                            copies: $0.copies, origin: $0.origin, playedTurn: $0.turn
                        )
                    },
                opponentPlays: opponentReveals
                    .filter { $0.firstSeenTurn == turn }
                    .map {
                        TrackedCard(
                            name: $0.name, cardID: $0.name,
                            cost: state.entities[$0.entityID]?.cost ?? 0,
                            copies: $0.copies, origin: $0.origin,
                            playedTurn: $0.firstSeenTurn
                        )
                    }
            )
        }
    }

    // MARK: - Player identification

    /// Both heroes print a CardID (heroes are public), so a printed card alone is not
    /// proof of side. The tell is the HAND only: the friendly hand is fully
    /// printed while the opponent's stays hidden. Deck printing cannot be used
    /// — deck transform mechanics print individual cards inside BOTH decks
    /// (observed: JAIL_430e1 enchantments in the opponent's deck).
    /// Returns true on the transition to resolved, so buffered reveals can be replayed.
    @discardableResult
    private mutating func resolveControllersIfPossible() -> Bool {
        guard !controllersResolved else { return false }

        let printedCards = state.entities.values.filter { entity in
            entity.cardID != nil
                && entity.cardID != "GAME_005"
                && entity.zone == "HAND"
        }
        guard let friendly = printedCards.first(where: { $0.controller != nil })?.controller else { return false }

        let hiddenControllers = Set(
            state.entities.values
                .filter { $0.cardID == nil && $0.controller != nil }
                .map(\.controller!)
        )
        .subtracting([friendly])

        guard hiddenControllers.count == 1, let opponent = hiddenControllers.first else { return false }

        friendlyController = friendly
        opponentController = opponent
        controllersResolved = true
        return true
    }

    // MARK: - Friendly plays

    /// A friendly play is a card that left the friendly hand into play; the coin
    /// (GAME_005) is excluded because it is not part of any constructed deck.
    private mutating func recordFriendlyPlayIfApplicable(entityID: Int) {
        guard !mulliganActive else { return }
        guard let entity = state.entities[entityID],
              let cardID = entity.cardID,
              cardID != "GAME_005",
              entity.controller == friendlyController,
              entity.hasEnteredHand,
              !friendlyPlayedEntityIDs.contains(entityID)
        else { return }
        friendlyPlayedEntityIDs.insert(entityID)

        let origin: CardOrigin = initialCardEntityIDs.contains(entityID) ? .original : .generated
        var sourceTrail: [String] = []
        if origin == .generated, let creatorID = entity.creatorEntityID,
           let creatorCardID = state.entities[creatorID]?.cardID {
            sourceTrail = [creatorCardID]
        }

        if let index = friendlyPlays.firstIndex(where: { $0.name == cardID && $0.origin == origin }) {
            friendlyPlays[index].copies += 1
        } else {
            friendlyPlays.append(
                FriendlyPlay(
                    entityID: entityID,
                    name: cardID,
                    cost: entity.cost ?? 0,
                    origin: origin,
                    turn: currentTurn,
                    sourceTrail: sourceTrail,
                    copies: 1
                )
            )
        }
    }

    /// The friendly hand as it stands right now (fully observable from the log),
    /// coin included; sorted by cost then name.
    private func friendlyHandCards() -> [TrackedCard] {
        friendlyEntitiesInCurrentPlay(includesCoin: true) { entity in
            entity.zone == "HAND" || (mulliganActive && entity.zone == "SETASIDE")
        }
    }

    /// Deck-view remaining cards: the queued deck's list minus everything that
    /// has physically left the deck (drawn cards count wherever they ended up;
    /// cards shuffled back in return naturally). Falls back to the observed
    /// deck entities when no deck code was associated.
    private func remainingFriendlyDeckCards() -> [TrackedCard] {
        if !deckListCards.isEmpty {
            // T5 quirk: re-dealt replacement cards keep zone=DECK while they
            // are actually in hand, and deck entities are not always moved on
            // the deal — so "drawn" is derived from ANY friendly entity whose
            // cardID belongs to the deck list and is not sitting in DECK.
            var drawnByCard: [String: Int] = [:]
            for entity in state.entities.values
            where entity.controller == friendlyController
                && !entity.wasCreatedRevealed
                && !(entity.zone == "SETASIDE" && !entity.hasEnteredHand)
                && !(mulliganActive && entity.zone == "SETASIDE")
            {
                let isLive: Bool
                if mulliganActive {
                    // During the mulligan window the client re-deals at
                    // submit time: replacements reach HAND a beat after
                    // SHUFFLE_DECK and sit in DECK until then. Count them
                    // only once they are actually in HAND; the old floor
                    // keeps retired pre-shuffle entities out.
                    if let floor = postShuffleEntityFloor {
                        isLive = entity.entityID >= floor || entity.zone == "HAND"
                    } else {
                        isLive = entity.zone != "DECK"
                    }
                } else {
                    // Mid-match the deal-time entities stay alive for the
                    // whole game: a draw is a plain DECK→HAND zone change
                    // (no re-materialization). Verified against the live
                    // client: deck-list entities outside DECK/SETASIDE
                    // reproduce ZoneDeck.m_cards exactly (6 = 6).
                    isLive = entity.zone != "DECK" && entity.zone != "SETASIDE"
                }
                if isLive, let cardID = entity.cardID {
                    drawnByCard[cardID, default: 0] += 1
                }
            }

            var rows = deckListCards.compactMap { entry -> TrackedCard? in
                let remaining = entry.count - (drawnByCard[entry.cardID] ?? 0)
                guard remaining > 0 else { return nil }
                // cost is filled by the card catalog at display time
                return TrackedCard(
                    name: entry.cardID,
                    cardID: entry.cardID,
                    cost: 0,
                    copies: remaining,
                    origin: .original,
                    playedTurn: 0
                )
            }

            // Shuffled-in cards currently sitting in the deck that are foreign
            // to the queued list (bombs, plagues, token copies). The T5 client
            // materializes these as plain DECK-zone entities with a readable
            // cardID, so they can be surfaced in the deck view like any other
            // deck card — marked .generated so the UI can tell them apart from
            // the original 30.
            let listIDs = Set(deckListCards.map(\.cardID))
            var shuffledIn: [String: Int] = [:]
            for entity in state.entities.values
            where entity.controller == friendlyController
                && entity.zone == "DECK"
                && entity.cardType != "ENCHANTMENT"
            {
                guard let cardID = entity.cardID, !listIDs.contains(cardID) else { continue }
                shuffledIn[cardID, default: 0] += 1
            }
            for (cardID, count) in shuffledIn.sorted(by: { $0.key < $1.key }) {
                rows.append(TrackedCard(
                    name: cardID,
                    cardID: cardID,
                    cost: 0,
                    copies: count,
                    origin: .generated,
                    playedTurn: 0
                ))
            }
            return rows
        }

        return friendlyEntitiesInCurrentPlay { entity in
            entity.zone == "DECK"
        }
    }

    /// Cards gained this game that entered the hand or were shuffled into the
    /// deck. Cards matching the known deck list are re-deals, not gains.
    private func friendlyShuffledCards() -> [TrackedCard] {
        let listIDs = Set(deckListCards.map(\.cardID))
        return friendlyEntitiesInCurrentPlay { entity in
            !initialCardEntityIDs.contains(entity.entityID)
                && (entity.hasEnteredHand || entity.zone == "DECK")
                && (listIDs.isEmpty || !listIDs.contains(entity.cardID ?? ""))
        }
    }

    /// Full derivation lineage (A ← B ← C), resolved at snapshot time so late
    /// DISPLAYED_CREATOR tags and late reveals still fill in the chain.
    private func creatorChain(of entityID: Int) -> [Int] {
        var chain: [Int] = []
        var current = state.entities[entityID]?.creatorEntityID
        var hops = 0
        while let id = current, hops < 5 {
            guard id != entityID, !chain.contains(id) else { break }
            chain.append(id)
            current = state.entities[id]?.creatorEntityID
            hops += 1
        }
        return chain
    }

    private func resolvedTrail(of entityID: Int) -> [String] {
        creatorChain(of: entityID).compactMap { state.entities[$0]?.cardID }
    }

    private func sideStats(controller: Int?) -> SideStats? {
        guard let controller else { return nil }
        // enchantments are not cards; revealed ones would inflate deck counts
        let own = state.entities.values.filter {
            $0.controller == controller && $0.cardType != "ENCHANTMENT"
        }

        let hand = own.filter { $0.zone == "HAND" }.count
        let deck: Int
        if !deckListCards.isEmpty {
            // zone counting lies in T5 (re-dealt cards keep zone=DECK); the
            // deck-list accounting matches the game's own counter
            deck = remainingFriendlyDeckCards().reduce(0) { $0 + $1.copies }
        } else {
            deck = own.filter { $0.zone == "DECK" }.count
        }
        // during the mulligan the replaced cards sit in SETASIDE while they
        // are still on screen / logically in the deck
        let setaside = mulliganActive
            ? own.filter { $0.zone == "SETASIDE" }.count
            : 0
        let handCount = max(hand, hand + setaside)
        let deckCount = deck + setaside
        let secrets = own.filter { $0.zone == "SECRET" }.count
        let boardATK = own
            .filter { $0.zone == "PLAY" && $0.cardType == "MINION" }
            .reduce(0) { $0 + ($1.atk ?? 0) }
        let weaponATK = own
            .filter { $0.zone == "PLAY" && $0.cardType == "WEAPON" }
            .reduce(0) { $0 + ($1.atk ?? 0) }

        // the live hero is whichever hero currently sits in PLAY
        let health: Int
        if
            let hero = own.first(where: { $0.cardType == "HERO" && $0.zone == "PLAY" }),
            let base = hero.health
        {
            health = max(base - (hero.damage ?? 0), 0) + (hero.armor ?? 0)
        } else {
            health = 0
        }

        return SideStats(
            handCount: handCount,
            deckCount: deckCount,
            boardATK: boardATK,
            weaponATK: weaponATK,
            secrets: secrets,
            currentHealth: health
        )
    }

    private func friendlyEntitiesInCurrentPlay(
        includesCoin: Bool = false,
        _ filter: (ObservedEntity) -> Bool
    ) -> [TrackedCard] {
        let entities = state.entities.values
            .filter { entity in
                entity.controller == friendlyController
                    && entity.cardID != nil
                    && entity.cardType != "ENCHANTMENT"
                    && (includesCoin || entity.cardID != "GAME_005")
                    && filter(entity)
            }
            .sorted { $0.entityID < $1.entityID }

        var order: [String] = []
        var byCard: [String: TrackedCard] = [:]
        for entity in entities {
            guard let cardID = entity.cardID else { continue }
            if var existing = byCard[cardID] {
                existing = TrackedCard(
                    id: existing.id,
                    name: existing.name,
                    cardID: existing.cardID,
                    cost: existing.cost,
                    copies: existing.copies + 1,
                    origin: existing.origin,
                    playedTurn: existing.playedTurn,
                    sourceTrail: existing.sourceTrail,
                    isBoardOnly: existing.isBoardOnly
                )
                byCard[cardID] = existing
            } else {
                order.append(cardID)
                byCard[cardID] = TrackedCard(
                    name: cardID,
                    cardID: cardID,
                    cost: entity.cost ?? 0,
                    origin: initialCardEntityIDs.contains(entity.entityID) ? .original : .generated,
                    playedTurn: 0
                )
            }
        }
        return order.compactMap { byCard[$0] }
    }

    // MARK: - Opponent reveals

    private mutating func recordRevealIfOpponent(entityID: Int) {
        if opponentController == nil {
            if !pendingRevealIDs.contains(entityID) {
                pendingRevealIDs.append(entityID)
            }
            return
        }

        guard !revealedEntityIDs.contains(entityID),
              let entity = state.entities[entityID],
              let cardID = entity.cardID,
              entity.cardType != "ENCHANTMENT",
              entity.controller == opponentController
        else { return }
        revealedEntityIDs.insert(entityID)

        // a reveal while sitting in the SECRET zone is a triggered secret
        if entity.zone == "SECRET" {
            revealedSecretIDs.append(cardID)
        }

        let origin: CardOrigin
        if phase == .partialRecording {
            origin = .unknown
        } else {
            origin = initialCardEntityIDs.contains(entityID) ? .original : .generated
        }

        var sourceTrail: [String] = []
        if origin == .generated, let creatorID = entity.creatorEntityID,
           let creatorCardID = state.entities[creatorID]?.cardID {
            sourceTrail = [creatorCardID]
        }

        if let index = opponentReveals.firstIndex(where: { $0.name == cardID && $0.origin == origin }) {
            opponentReveals[index].copies += 1
        } else {
            opponentReveals.append(
                OpponentReveal(
                    entityID: entityID,
                    name: cardID,
                    origin: origin,
                    firstSeenTurn: currentTurn,
                    sourceTrail: sourceTrail,
                    copies: 1
                )
            )
        }
    }
}

extension MatchSessionTracker {
    /// 诊断：列出参与"已抽"计数的实体。
    public func auditDrawn() -> [String] {
        var lines: [String] = []
        let listIDs = Set(deckListCards.map(\.cardID))
        lines.append("deckListCards=\(deckListCards.count) friendly=\(friendlyController.map(String.init) ?? "nil") phase=\(phase) floor=\(postShuffleEntityFloor.map(String.init) ?? "nil") mulliganActive=\(mulliganActive)")
        for entity in state.entities.values
        where entity.controller == friendlyController
            && listIDs.contains(entity.cardID ?? "") {
            lines.append("id=\(entity.entityID) \(entity.cardID ?? "?") zone=\(entity.zone ?? "?") createdRevealed=\(entity.wasCreatedRevealed) enteredHand=\(entity.hasEnteredHand) type=\(entity.cardType ?? "?")")
        }
        return lines.sorted()
    }
}
