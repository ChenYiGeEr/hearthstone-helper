import SwiftUI
import HearthstoneCore

/// Merge memory counts (authoritative for deck/hand/board) into log-based SideStats
func mergedSideStats(logStats: SideStats?, memoryInMatch: Bool, memoryCounts: MirrorMemoryStore.ZoneCounts?, isOpponent: Bool) -> SideStats? {
    guard let log = logStats else { return nil }
    guard memoryInMatch, let counts = memoryCounts else { return log }

    // Opponent counts are friendly in memory if isOpponent=true
    let memDeck = isOpponent ? counts.opponentDeck : counts.friendlyDeck
    let memHand = isOpponent ? counts.opponentHand : counts.friendlyHand
    let memBoard = isOpponent ? counts.opponentBoard : counts.friendlyBoard

    return SideStats(
        handCount: memHand ?? log.handCount,
        deckCount: memDeck ?? log.deckCount,
        boardATK: log.boardATK,
        weaponATK: log.weaponATK,
        secrets: log.secrets,
        currentHealth: log.currentHealth
    )
}

/// Left overlay: opponent's observed cards grouped by their current zone
/// (牌库中/手牌中/其他), Firestone style. Origin honesty stays as row glyphs.
struct OpponentOverlayPanel: View {
    let store: MatchStore
    @State private var hoveredCardID: String?
    @Environment(\.colorScheme) private var systemScheme

    private var chromeContext: HearthContext {
        store.interfaceContext(systemIsLight: systemScheme == .light, overlay: true)
    }

    var body: some View {
        let context = HearthChrome.install(chromeContext)
        let match = store.match
        let friendlyClass = store.deckLibrary.decks
            .first { $0.id == match.playerDeckID }?.className ?? ""
        let friendly = match.friendlyStats
        let lethal = (friendly?.boardATK ?? 0) + (friendly?.weaponATK ?? 0)
            + CardCatalog.heroPowerDamage(classLabel: friendlyClass)
        let threatened = lethal >= (match.opponentStats?.currentHealth ?? .max)

        let rankText: String? = {
            guard let league = store.live.opponent?.leagueID else { return nil }
            let name = HearthChrome.league(MirrorLiveStore.leagueName(league) ?? "?")
            return league == 5 ? name : "\(name) ★\(store.live.opponent?.stars ?? 0)"
        }()

        // Merge opponent stats with memory counts (memory is authoritative for counts)
        let mergedOpponentStats = mergedSideStats(
            logStats: match.opponentStats,
            memoryInMatch: store.memory.inMatch,
            memoryCounts: store.memory.counts,
            isOpponent: true
        )
        let previousEncounter = previousEncounter(for: match)

        return OverlayPanelShell(
            title: HearthChrome.L("对手记录", "Opponent"),
            subtitle: [HearthChrome.phrase(match.opponentClass), rankText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            accent: .mintSoft,
            store: store,
            hoveredCardID: $hoveredCardID
        ) {
            SideStatsBar(
                stats: mergedOpponentStats,
                turnStartedAt: match.turnStartedAt,
                showsCountdown: match.currentActorIsOpponent == true,
                healthThreatened: threatened && (mergedOpponentStats?.currentHealth ?? 30) > 0
            )

            if let previousEncounter {
                rematchNote(previousEncounter)
            }

            OverlayScrollView {
                if let previousEncounter {
                    previousSeenSection(previousEncounter)
                }
                secretsBlock(match)
                zoneGroup(
                    HearthChrome.L("牌库", "Deck"),
                    tint: .goldSoft,
                    total: mergedOpponentStats?.deckCount,
                    cards: match.opponentCards.filter { $0.currentZone == "DECK" },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    showsCount: false,
                    animated: HearthChrome.motion != .off
                )
                OpponentInferenceView(
                    cards: match.opponentCards,
                    deckCount: mergedOpponentStats?.deckCount,
                    catalog: store.cardData.catalog,
                    extraOnly: true
                )
                zoneGroup(
                    HearthChrome.L("手牌", "Hand"),
                    tint: .mintSoft,
                    total: mergedOpponentStats?.handCount,
                    cards: match.opponentCards.filter { $0.currentZone == "HAND" },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    showsCount: false,
                    animated: HearthChrome.motion != .off
                )
                zoneGroup(
                    HearthChrome.L("其他", "Other"),
                    tint: .mistSoft,
                    total: nil,
                    cards: match.opponentCards.filter { card in
                        card.currentZone != "DECK" && card.currentZone != "HAND"
                    },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    hideWhenEmpty: true,
                    animated: HearthChrome.motion != .off
                )
            }
        }
        .environment(\.hearthContext, context)
        .preferredColorScheme(context.isLight ? .light : .dark)
        .softAppear()
    }
}

/// Right overlay: friendly deck view / current hand / play history / gains.
struct PlayerOverlayPanel: View {
    let store: MatchStore
    @State private var hoveredCardID: String?
    @Environment(\.colorScheme) private var systemScheme

    private var chromeContext: HearthContext {
        store.interfaceContext(systemIsLight: systemScheme == .light, overlay: true)
    }

    var body: some View {
        let context = HearthChrome.install(chromeContext)
        let match = store.match
        let friendlyClass = store.deckLibrary.decks
            .first { $0.id == match.playerDeckID }?.className ?? ""
        let friendly = match.friendlyStats
        let lethal = (friendly?.boardATK ?? 0) + (friendly?.weaponATK ?? 0)
            + CardCatalog.heroPowerDamage(classLabel: friendlyClass)

        // Merge friendly stats with memory counts
        let mergedFriendlyStats = mergedSideStats(
            logStats: match.friendlyStats,
            memoryInMatch: store.memory.inMatch,
            memoryCounts: store.memory.counts,
            isOpponent: false
        )

        return OverlayPanelShell(
            title: HearthChrome.L("己方牌库", "Your deck"),
            subtitle: match.playerDeckName,
            accent: .goldSoft,
            store: store,
            hoveredCardID: $hoveredCardID
        ) {
            SideStatsBar(
                stats: mergedFriendlyStats,
                turnStartedAt: match.turnStartedAt,
                showsCountdown: match.currentActorIsOpponent == false,
                lethal: lethal
            )

            winrateLine(match)

            if store.mulliganAdviceEnabled,
               let mulligan = store.live.mulligan,
               !mulligan.done,
               !mulligan.cardIDs.isEmpty {
                MulliganAdviceView(hints: MulliganAdvice.hints(cardIDs: mulligan.cardIDs, catalog: store.cardData.catalog))
            }

            OverlayScrollView {
                friendlyDeckSection(
                    cards: match.playerRemainingCards.sorted {
                        $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
                    },
                    total: mergedFriendlyStats?.deckCount,
                    matchID: match.id,
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    trailing: { card in
                        var parts: [String] = []
                        if card.origin != .original { parts.append(HearthChrome.phrase("洗入")) }
                        if card.copies > 1 { parts.append("×\(card.copies)") }
                        return parts.isEmpty ? nil : parts.joined(separator: " ")
                    }
                )
                zoneGroup(
                    HearthChrome.L("手牌", "Hand"),
                    tint: .mintSoft,
                    total: mergedFriendlyStats?.handCount,
                    cards: store.playerHandCardsResolved.sorted {
                        $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
                    },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    showsCount: false,
                    animated: HearthChrome.motion != .off
                )
                if !match.turns.isEmpty {
                    OverlaySection(
                        title: HearthChrome.L("节奏", "Pace"),
                        count: match.turns.count,
                        tint: .goldSoft,
                        startsExpanded: false
                    ) {
                        PaceCompareView(curve: [], turns: match.turns, compact: true)
                    }
                }
                zoneGroup(
                    HearthChrome.L("已打出", "Played"),
                    tint: .mistSoft,
                    cards: match.playerPlayedCards.reversed(),
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    hideWhenEmpty: true,
                    animated: HearthChrome.motion != .off
                )
            }
        }
        .environment(\.hearthContext, context)
        .preferredColorScheme(context.isLight ? .light : .dark)
        .softAppear()
    }

    /// "对阵 恶魔猎手 66.7% 2/1" from the local history of this exact deck.
    @ViewBuilder
    private func winrateLine(_ match: MatchRecord) -> some View {
        let stats = store.history.stats(againstClass: match.opponentClass, deckID: match.playerDeckID)
        if stats.wins + stats.losses > 0 {
            HStack(spacing: 6) {
                Text(HearthChrome.L("对阵 \(HearthChrome.phrase(match.opponentClass))", "vs \(HearthChrome.phrase(match.opponentClass))"))
                    .foregroundStyle(Color.mistSoft)
                Text("\(Int(stats.winRate * 100))%")
                    .foregroundStyle(stats.winRate >= 0.5 ? Color.mintSoft : Color.goldSoft)
                Text("\(stats.wins)/\(stats.losses)")
                    .foregroundStyle(Color.mistSoft)
                Spacer()
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Grouping

private func OverlayScrollView(@ViewBuilder content: () -> some View) -> some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.vertical, 2)
    }
}

@MainActor
@ViewBuilder
private func zoneGroup(
    _ title: String,
    tint: Color,
    total: Int? = nil,
    cards: [TrackedCard],
    store: MatchStore,
    hoveredCardID: Binding<String?>,
    showsCount: Bool = true,
    hideWhenEmpty: Bool = false,
    animated: Bool = false,
    trailing: ((TrackedCard) -> String?)? = nil
) -> some View {
    let revealed = cards.reduce(0) { $0 + $1.copies }
    let unknown = max((total ?? revealed) - revealed, 0)
    if hideWhenEmpty && cards.isEmpty && unknown == 0 {
        EmptyView()
    } else {
        OverlaySection(title: title, count: revealed + unknown, tint: tint, showsCount: showsCount) {
            // Identity includes origin so an original and a generated copy of the
            // same card are not collapsed into one ForEach row. Do not use an
            // insertion transition here: live log updates are not inside
            // withAnimation, so a fade-in stays at opacity 0 and the row never
            // appears. Opponent reveals are almost all insertions; the friendly
            // deck mostly removes rows, which is why only the left panel looked frozen.
            ForEach(cards, id: \.overlayRowID) { card in
                OverlayCardRow(card: card, trailing: (trailing ?? zoneTrailing)(card), store: store, hoveredCardID: hoveredCardID)
                    .transition(.identity)
            }
            if unknown > 0 {
                HStack(spacing: 6) {
                    Text(HearthChrome.L("未知", "Unknown"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mistSoft)
                    Spacer()
                    Text("×\(unknown)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.mistSoft)
                        .contentTransition(.numericText())
                        .animation(animated ? HearthChrome.Motion.optional(.easeOut(duration: 0.18)) : nil, value: unknown)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
        }
    }
}

/// Right-overlay remaining deck. Draw and shuffle are one-shot horizontal
/// offsets on a stable row id. Opacity stays 1 so a log update outside
/// `withAnimation` cannot leave the row invisible.
@MainActor
@ViewBuilder
private func friendlyDeckSection(
    cards: [TrackedCard],
    total: Int?,
    matchID: UUID,
    store: MatchStore,
    hoveredCardID: Binding<String?>,
    trailing: @escaping (TrackedCard) -> String?
) -> some View {
    let revealed = cards.reduce(0) { $0 + $1.copies }
    let unknown = max((total ?? revealed) - revealed, 0)
    let animated = HearthChrome.motion != .off
    OverlaySection(
        title: HearthChrome.L("牌库", "Deck"),
        count: revealed + unknown,
        tint: .goldSoft,
        showsCount: false
    ) {
        FriendlyDeckList(
            cards: cards,
            matchID: matchID,
            store: store,
            hoveredCardID: hoveredCardID,
            trailing: trailing
        )
        if unknown > 0 {
            HStack(spacing: 6) {
                Text(HearthChrome.L("未知", "Unknown"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.mistSoft)
                Spacer()
                Text("×\(unknown)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.mistSoft)
                    .contentTransition(.numericText())
                    .animation(animated ? HearthChrome.Motion.optional(.easeOut(duration: 0.18)) : nil, value: unknown)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
    }
}

/// How far a deck row travels for one draw or shuffle.
private enum DeckRowMotion {
    static var travel: CGFloat {
        switch HearthChrome.motion {
        case .off: 0
        case .light: 72
        case .flashy: 160
        }
    }

    static var animation: Animation {
        switch HearthChrome.motion {
        case .off: .linear(duration: 0)
        case .light: .easeOut(duration: 0.22)
        case .flashy: .spring(response: 0.42, dampingFraction: 0.86)
        }
    }

    /// More than a mulligan's worth of membership change is a deck reload, not
    /// a draw or a shuffle.
    static let bulkLimit = 8
}

private struct DeckDeparture: Identifiable {
    let id: UUID
    let rowID: String
    let card: TrackedCard
    let trailing: String?
}

private enum DeckRowItem: Identifiable {
    case live(TrackedCard)
    case leave(DeckDeparture)

    var id: String {
        switch self {
        case .live(let card): card.overlayRowID
        case .leave(let departure): "leave|\(departure.id.uuidString)"
        }
    }
}

private struct FriendlyDeckList: View {
    let cards: [TrackedCard]
    let matchID: UUID
    let store: MatchStore
    @Binding var hoveredCardID: String?
    let trailing: (TrackedCard) -> String?

    @State private var seededMatch: UUID?
    @State private var previousCards: [String: TrackedCard] = [:]
    @State private var departures: [DeckDeparture] = []
    @State private var shuffleToken: [String: Int] = [:]

    private var signature: String {
        cards.map { "\($0.overlayRowID):\($0.copies)" }.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rowItems) { item in
                switch item {
                case .live(let card):
                    DeckLiveRow(
                        card: card,
                        trailing: trailing(card),
                        store: store,
                        hoveredCardID: $hoveredCardID,
                        matchID: matchID,
                        shuffleToken: shuffleToken[card.overlayRowID] ?? 0,
                        incoming: isIncoming(card)
                    )
                    .transition(.identity)
                case .leave(let departure):
                    DeckLeaveRow(
                        card: departure.card,
                        trailing: departure.trailing,
                        store: store,
                        hoveredCardID: $hoveredCardID
                    ) {
                        departures.removeAll { $0.id == departure.id }
                    }
                    .transition(.identity)
                }
            }
        }
        .clipped()
        .onAppear {
            if seededMatch != matchID {
                reseed()
            }
        }
        .onChange(of: matchID) { _, _ in
            reseed()
        }
        .onChange(of: signature) { _, _ in
            applyDiff()
        }
    }

    private var rowItems: [DeckRowItem] {
        var items: [DeckRowItem] = []
        var placed: Set<UUID> = []
        for card in cards {
            items.append(.live(card))
            for departure in departures where departure.rowID == card.overlayRowID {
                items.append(.leave(departure))
                placed.insert(departure.id)
            }
        }
        for departure in departures where !placed.contains(departure.id) {
            let index = items.firstIndex { item in
                let other = item.sortKey
                return departure.sortKey < other
            } ?? items.endIndex
            items.insert(.leave(departure), at: index)
        }
        return items
    }

    private func isIncoming(_ card: TrackedCard) -> Bool {
        guard seededMatch == matchID, HearthChrome.motion != .off, !isBulkChange else { return false }
        let old = previousCards[card.overlayRowID]?.copies ?? 0
        return card.copies > old
    }

    private var isBulkChange: Bool {
        guard seededMatch == matchID else { return false }
        var moving = 0
        for card in cards {
            let old = previousCards[card.overlayRowID]?.copies ?? 0
            if card.copies > old { moving += card.copies - old }
        }
        for (id, card) in previousCards {
            let newCopies = cards.first { $0.overlayRowID == id }?.copies ?? 0
            if card.copies > newCopies { moving += card.copies - newCopies }
        }
        return moving > DeckRowMotion.bulkLimit
    }

    private func reseed() {
        seededMatch = matchID
        previousCards = Dictionary(cards.map { ($0.overlayRowID, $0) }, uniquingKeysWith: { $1 })
        departures = []
        shuffleToken = [:]
    }

    private func applyDiff() {
        if seededMatch != matchID {
            reseed()
            return
        }
        let next = Dictionary(cards.map { ($0.overlayRowID, $0) }, uniquingKeysWith: { $1 })
        var added = 0
        var removed = 0
        for (id, card) in next {
            let old = previousCards[id]?.copies ?? 0
            if card.copies > old { added += card.copies - old }
        }
        for (id, card) in previousCards {
            let new = next[id]?.copies ?? 0
            if card.copies > new { removed += card.copies - new }
        }
        let moving = added + removed
        guard HearthChrome.motion != .off, moving > 0, moving <= DeckRowMotion.bulkLimit else {
            previousCards = next
            return
        }
        for (id, card) in next {
            let old = previousCards[id]?.copies ?? 0
            if card.copies > old {
                shuffleToken[id, default: 0] += 1
            }
        }
        for (id, card) in previousCards {
            let newCopies = next[id]?.copies ?? 0
            let gone = card.copies - newCopies
            guard gone > 0 else { continue }
            let shown = leavingCopy(of: next[id] ?? card)
            for _ in 0..<gone {
                departures.append(DeckDeparture(
                    id: UUID(),
                    rowID: id,
                    card: shown,
                    trailing: trailing(shown)
                ))
            }
        }
        previousCards = next
    }

    /// One physical card leaving the stack. The live row keeps the real count.
    private func leavingCopy(of card: TrackedCard) -> TrackedCard {
        TrackedCard(
            name: card.name,
            cardID: card.cardID,
            cost: card.cost,
            copies: 1,
            origin: card.origin,
            playedTurn: card.playedTurn,
            sourceTrail: card.sourceTrail,
            isBoardOnly: card.isBoardOnly,
            currentZone: card.currentZone
        )
    }
}

private extension DeckRowItem {
    var sortKey: (Int, String, Int) {
        switch self {
        case .live(let card): (card.cost, card.name, 0)
        case .leave(let departure): (departure.card.cost, departure.card.name, 1)
        }
    }
}

private extension DeckDeparture {
    var sortKey: (Int, String, Int) { (card.cost, card.name, 1) }
}

/// Shuffle-in: the row starts to the left and slides right into its slot.
/// The resting offset is always 0, and opacity is never animated.
private struct DeckLiveRow: View {
    let card: TrackedCard
    let trailing: String?
    let store: MatchStore
    @Binding var hoveredCardID: String?
    let matchID: UUID
    let shuffleToken: Int
    /// True on the frame the copy count goes up, before the snapshot catches up.
    let incoming: Bool

    @State private var x: CGFloat = 0
    @State private var playedToken = 0
    @State private var armedWave = 0
    @State private var playedMatch: UUID?
    /// Bumps after the row is parked to the left, so the slide home starts
    /// from that frame instead of being batched away.
    @State private var launch = 0

    private var shownX: CGFloat {
        if launch == 0 && incoming && HearthChrome.motion != .off {
            return -DeckRowMotion.travel
        }
        return x
    }

    var body: some View {
        OverlayCardRow(card: card, trailing: trailing, store: store, hoveredCardID: $hoveredCardID)
            .offset(x: shownX)
            .onAppear { playShuffle() }
            .onChange(of: shuffleToken) { _, _ in playShuffle() }
            .onChange(of: incoming) { _, _ in playShuffle() }
            .onChange(of: matchID) { _, _ in
                playedMatch = matchID
                playedToken = 0
                armedWave = 0
                launch = 0
                x = 0
            }
            .onChange(of: launch) { _, launch in
                guard launch > 0 else { return }
                withAnimation(DeckRowMotion.animation) {
                    x = 0
                }
            }
    }

    private func playShuffle() {
        if playedMatch != matchID {
            playedMatch = matchID
            playedToken = 0
            armedWave = 0
            launch = 0
            x = 0
        }
        let wave = max(shuffleToken, incoming ? playedToken + 1 : playedToken)
        guard wave > armedWave else { return }
        armedWave = wave
        if shuffleToken > playedToken {
            playedToken = shuffleToken
        }
        guard HearthChrome.motion != .off else {
            x = 0
            return
        }
        x = -DeckRowMotion.travel
        launch += 1
    }
}

/// Draw: a one-shot copy of the row slides left, then leaves the list.
/// Opacity stays 1 for the whole slide.
private struct DeckLeaveRow: View {
    let card: TrackedCard
    let trailing: String?
    let store: MatchStore
    @Binding var hoveredCardID: String?
    let onDone: () -> Void

    @State private var x: CGFloat = 0
    @State private var started = false

    var body: some View {
        OverlayCardRow(card: card, trailing: trailing, store: store, hoveredCardID: $hoveredCardID)
            .offset(x: x)
            .allowsHitTesting(false)
            .onAppear {
                guard !started else { return }
                started = true
                guard HearthChrome.motion != .off else {
                    onDone()
                    return
                }
                let delay: TimeInterval = HearthChrome.motion == .flashy ? 0.5 : 0.26
                withAnimation(DeckRowMotion.animation) {
                    x = -DeckRowMotion.travel
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        onDone()
                    }
                }
            }
    }
}

private extension TrackedCard {
    /// Stable across log snapshots (the UUID `id` is new every poll) and unique
    /// when the same cardID exists as both an original and a generated copy.
    var overlayRowID: String { "\(rowKey)|\(origin.rawValue)" }
}

private func zoneTrailing(_ card: TrackedCard) -> String? {
        if card.playedTurn > 0 {
            return HearthChrome.L("回合 \(card.playedTurn)", "Turn \(card.playedTurn)")
        }
    if card.copies > 1 {
        return "×\(card.copies)"
    }
    return nil
}

// MARK: - Shared shell

// MARK: - Rematch note & secrets

private extension OpponentOverlayPanel {
    /// 同一对手账号、比这一局更早的最近一局。
    func previousEncounter(for match: MatchRecord) -> MatchHistoryEntry? {
        guard let account = match.opponentAccountID else { return nil }
        return store.history.entries
            .filter { $0.opponentAccountID == account && $0.startedAt < match.startedAt }
            .max(by: { $0.startedAt < $1.startedAt })
    }

    /// "再遇"只留日期和胜负。历史里的 deckName 是你自己的卡组，不能写成他的。
    @ViewBuilder
    func rematchNote(_ previous: MatchHistoryEntry) -> some View {
        let won = previous.result == .win
        let outcomeZh = won ? "胜" : previous.result == .loss ? "负" : "平"
        let outcomeEn = won ? "W" : previous.result == .loss ? "L" : "T"
        let day = previous.startedAt.formatted(.dateTime.month().day())
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .bold))
            Text(HearthChrome.L("再遇 \(day)：你\(outcomeZh)", "Rematch \(day): you \(outcomeEn)"))
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.goldSoft)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.goldSoft.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.goldSoft.opacity(0.32), lineWidth: 1))
    }

    /// 上一局见到的牌。有 cardID、不是纯场面衍生物。这一局已经见过的也留着。
    @ViewBuilder
    func previousSeenSection(_ previous: MatchHistoryEntry) -> some View {
        let cards = previousSeenCards(previous)
        if !cards.isEmpty {
            OverlaySection(
                title: HearthChrome.L("上次", "Last time"),
                count: cards.reduce(0) { $0 + $1.copies },
                tint: .mistSoft,
                startsExpanded: false
            ) {
                ForEach(cards, id: \.overlayRowID) { card in
                    OverlayCardRow(
                        card: card,
                        trailing: "×\(card.copies)",
                        store: store,
                        hoveredCardID: $hoveredCardID
                    )
                }
            }
        }
    }

    func previousSeenCards(_ previous: MatchHistoryEntry) -> [TrackedCard] {
        let catalog = store.cardData.catalog
        let source = (previous.opponentCards ?? []).filter { card in
            guard let cardID = card.cardID, !cardID.isEmpty else { return false }
            return !card.isBoardOnly
        }
        let grouped = Dictionary(grouping: source) { $0.cardID ?? $0.name }
        return grouped.map { cardID, group in
            let copies = group.reduce(0) { $0 + max($1.copies, 1) }
            let storedCost = group.map(\.cost).max() ?? 0
            let cost = catalog?.cost(for: cardID) ?? storedCost
            let storedName = group.map(\.name).first { $0 != cardID } ?? cardID
            let name = catalog?.info(for: cardID)?.name ?? storedName
            let origin: CardOrigin = group.contains { $0.origin == .original }
                ? .original
                : (group.contains { $0.origin == .generated } ? .generated : .unknown)
            return TrackedCard(
                name: name,
                cardID: cardID,
                cost: cost,
                copies: copies,
                origin: origin,
                playedTurn: 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 奥秘块：对手挂着奥秘时列出该职业奥秘池，触发过的划掉。
    @ViewBuilder
    func secretsBlock(_ match: MatchRecord) -> some View {
        let count = match.opponentStats?.secrets ?? 0
        if count > 0, let catalog = store.cardData.catalog {
            let pool = catalog.secretCardIDs(classLabel: match.opponentClass)
            OverlaySection(title: HearthChrome.L("奥秘", "Secrets"), count: count, tint: .goldSoft) {
                ForEach(pool, id: \.self) { cardID in
                    let triggered = match.revealedSecrets.contains(cardID)
                    HStack(spacing: 8) {
                        Text("\(catalog.cost(for: cardID) ?? 0)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.inkDeep)
                            .frame(width: 18, height: 18)
                            .background(Color.goldSoft, in: Circle())
                        Text(catalog.displayName(for: cardID))
                            .font(.system(size: 12, weight: triggered ? .regular : .semibold))
                            .foregroundStyle(triggered ? Color.mistSoft.opacity(0.7) : Color.hearthText)
                            .strikethrough(triggered, color: .mistSoft)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Color.inkDeep.opacity(triggered ? 0.28 : 0.5),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }
        }
    }
}

private extension OpponentOverlayPanel {
    var isFinished: Bool {
        if case .finished = store.status { return true }
        return false
    }
}

private extension PlayerOverlayPanel {
    var isFinished: Bool {
        if case .finished = store.status { return true }
        return false
    }
}

private extension CardOrigin {
    var tint: Color {
        switch self {
        case .original: .goldSoft
        case .generated: .mintSoft
        case .unknown: .mistSoft
        }
    }
}

private struct OverlayPanelShell<Content: View>: View {
    let title: String
    let subtitle: String
    let accent: Color
    let store: MatchStore
    @Binding var hoveredCardID: String?
    @ViewBuilder let content: Content
    @Environment(\.hearthContext) private var hearthContext

    var body: some View {
        let _ = HearthChrome.install(hearthContext)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .kerning(-0.2)
                        .foregroundStyle(Color.hearthText)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.mistSoft)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.mistSoft)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.hearthText.opacity(0.08), in: Capsule())
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.8), radius: 4)
            }
            .overlay {
                OverlayDragHandle()
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            Color.inkDeep.opacity(HearthChrome.isLight ? min(store.overlayBackgroundOpacity + 0.28, 0.94) : store.overlayBackgroundOpacity),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [accent, accent.opacity(0.15)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 3)
            .padding(.horizontal, 22)
            .padding(.top, 7)
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [accent.opacity(0.75), Color.lineSoft, accent.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .overlay(alignment: .trailing) {
            hoverPreview
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.mistSoft.opacity(0.8))
                    .allowsHitTesting(false)
                OverlayResizeGrip()
            }
            .frame(width: 18, height: 18)
            .padding(6)
        }
    }

    @ViewBuilder
    private var hoverPreview: some View {
        if
            !store.isOverlayPassthrough,
            let cardID = hoveredCardID,
            let image = store.cardImages.fullImage(for: cardID)
        {
            Image(nsImage: image)
                .resizable()
                .frame(width: 232, height: 232 * 388.0 / 256.0)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.goldSoft.opacity(0.85), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 16, y: 6)
                .padding(.trailing, 14)
                .allowsHitTesting(false)
        }
    }
}

/// Board vitals strip: attack / health / hand / deck plus combat helpers —
/// lethal estimate on the friendly side, threatened health on the opponent
/// side, fatigue warning at ≤3 cards, and the acting side's turn countdown.
private struct SideStatsBar: View {
    let stats: SideStats?
    let turnStartedAt: Date?
    var showsCountdown: Bool = true
    /// Lethal estimate (board + weapon + hero power); shown as 杀 N on the
    /// friendly panel only.
    var lethal: Int? = nil
    /// True when the opponent's health is within the lethal estimate.
    var healthThreatened: Bool = false
    @Environment(\.hearthContext) private var hearthContext

    private static let turnLength: TimeInterval = 75

    var body: some View {
        let _ = HearthChrome.install(hearthContext)
        return HStack(spacing: 10) {
            item(HearthChrome.L("攻", "Atk"), stats?.boardATK, tint: .goldSoft)
            item(
                HearthChrome.L("血", "HP"),
                stats?.currentHealth,
                tint: healthThreatened ? Color(red: 0.9, green: 0.25, blue: 0.2) : .mintSoft,
                suffix: healthThreatened ? " 💀" : nil
            )
            item(HearthChrome.L("手", "Hand"), stats?.handCount, tint: .mistSoft)
            item(
                HearthChrome.L("库", "Deck"),
                stats?.deckCount,
                tint: (stats?.deckCount ?? 99) <= 3 ? Color(red: 0.9, green: 0.6, blue: 0.2) : .mistSoft,
                suffix: (stats?.deckCount ?? 99) <= 3 ? " ⚠" : nil
            )
            if let lethal {
                item(HearthChrome.L("杀", "Kill"), lethal, tint: Color(red: 0.9, green: 0.25, blue: 0.2))
            }
            Spacer()
            if showsCountdown {
                clock
            }
        }
        .font(.system(size: 11, weight: .bold).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.inkDeep.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.hearthText.opacity(0.12), lineWidth: 1)
        )
    }

    private func item(_ label: String, _ value: Int?, tint: Color, suffix: String? = nil) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tint)
            Text((value.map(String.init) ?? "—") + (suffix ?? ""))
                .foregroundStyle(Color.hearthText)
                .contentTransition(.numericText())
                .animation(HearthChrome.Motion.optional(.easeOut(duration: 0.2)), value: value ?? -1)
        }
    }

    @ViewBuilder
    private var clock: some View {
        if let turnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(turnStartedAt)
                let remaining = max(0, Int(Self.turnLength - elapsed))
                Text("⏱\(remaining)s")
                    .foregroundStyle(remaining <= 10 ? Color.goldSoft : Color.mistSoft)
            }
        }
    }
}

private struct OverlaySection<Content: View>: View {
    let title: String
    let count: Int
    let tint: Color
    var showsCount: Bool = true
    var startsExpanded: Bool = true
    @State private var isExpanded: Bool?
    @ViewBuilder let content: Content
    @Environment(\.hearthContext) private var hearthContext

    private var expanded: Bool { isExpanded ?? startsExpanded }

    var body: some View {
        let _ = HearthChrome.install(hearthContext)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                HearthChrome.Motion.run {
                    isExpanded = !expanded
                }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.hearthText.opacity(0.85))
                        .frame(width: 3, height: 11)
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.hearthText)
                    Spacer()
                    if showsCount {
                        Text("\(count)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color.hearthText.opacity(0.9))
                            .contentTransition(.numericText())
                            .animation(HearthChrome.Motion.optional(.spring(response: 0.28, dampingFraction: 0.9)), value: count)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.hearthText.opacity(0.7))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }
}

/// Firestone-style row: rarity-colored cost gem, name, count badge, over the
/// card's own name-band art as the row background.
private struct OverlayCardRow: View {
    let card: TrackedCard
    var trailing: String?
    let store: MatchStore
    @Binding var hoveredCardID: String?
    @State private var hovering = false
    @Environment(\.hearthContext) private var hearthContext

    private var lookupID: String {
        card.cardID ?? card.name
    }

    var body: some View {
        let _ = HearthChrome.install(hearthContext)
        return HStack(spacing: 8) {
            Text("\(card.cost)")
                .font(.system(size: 10, weight: .heavy).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Self.rarityColor(store.cardData.catalog?.rarity(for: lookupID)), in: Circle())
                .shadow(color: .black.opacity(0.5), radius: 1)

            if card.origin != .original {
                Image(systemName: card.origin == .generated ? "arrow.triangle.branch" : "questionmark.circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(card.origin.tint)
            }

            Text(card.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.85), radius: 1)

            Spacer(minLength: 4)

            if let trailing {
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.85), radius: 1)
                    .contentTransition(.numericText())
            }

            if store.cardData.catalog?.isDirectDamage(lookupID) == true {
                Text("💥")
                    .font(.system(size: 10))
                    .shadow(color: .black.opacity(0.8), radius: 1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.88 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                hoveredCardID = lookupID
            } else if hoveredCardID == lookupID {
                hoveredCardID = nil
            }
        }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    /// The row borrows its card's own name-band art; a dark wash keeps the
    /// overlaid text readable, and a plain tint is used until art arrives.
    @ViewBuilder
    private var rowBackground: some View {
        if let strip = store.cardImages.strip(for: lookupID) {
            Image(nsImage: strip)
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Color.black.opacity(0.34))
        } else {
            Color.cardStrip.opacity(0.72)
        }
    }

    /// Rarity gems: 白=普通, 蓝=稀有, 紫=史诗, 橙=传说.
    private static func rarityColor(_ rarity: String?) -> Color {
        switch rarity {
        case "LEGENDARY": Color(red: 0.90, green: 0.49, blue: 0.13)
        case "EPIC": Color(red: 0.61, green: 0.35, blue: 0.72)
        case "RARE": Color(red: 0.28, green: 0.56, blue: 0.85)
        default: Color(white: 0.62)
        }
    }
}

private struct OverlayEmpty: View {
    let text: String
    @Environment(\.hearthContext) private var hearthContext

    var body: some View {
        let _ = HearthChrome.install(hearthContext)
        return HStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Color.mistSoft.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}
