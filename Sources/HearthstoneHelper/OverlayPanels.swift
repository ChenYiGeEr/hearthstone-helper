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

    var body: some View {
        let match = store.match
        let friendlyClass = store.deckLibrary.decks
            .first { $0.id == match.playerDeckID }?.className ?? ""
        let friendly = match.friendlyStats
        let lethal = (friendly?.boardATK ?? 0) + (friendly?.weaponATK ?? 0)
            + CardCatalog.heroPowerDamage(classLabel: friendlyClass)
        let threatened = lethal >= (match.opponentStats?.currentHealth ?? .max)

        let rankText: String? = {
            guard let league = store.live.opponent?.leagueID else { return nil }
            let name = MirrorLiveStore.leagueName(league) ?? "?"
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

        OverlayPanelShell(
            title: "对手记录",
            subtitle: [match.opponentClass, rankText].compactMap { $0 }.joined(separator: " · "),
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
                // counts come from the real zone totals (hidden cards included);
                // unrevealed cards show up as "未知卡牌" placeholders
                zoneGroup(
                    "牌库中",
                    tint: .goldSoft,
                    total: mergedOpponentStats?.deckCount,
                    cards: match.opponentCards.filter { $0.currentZone == "DECK" },
                    store: store,
                    hoveredCardID: $hoveredCardID
                )
                zoneGroup(
                    "手牌中",
                    tint: .mintSoft,
                    total: mergedOpponentStats?.handCount,
                    cards: match.opponentCards.filter { $0.currentZone == "HAND" },
                    store: store,
                    hoveredCardID: $hoveredCardID
                )
                zoneGroup(
                    "其他",
                    tint: .mistSoft,
                    total: nil,
                    cards: match.opponentCards.filter { card in
                        card.currentZone != "DECK" && card.currentZone != "HAND"
                    },
                    store: store,
                    hoveredCardID: $hoveredCardID
                )
            }
        }
    }
}

/// Right overlay: friendly deck view / current hand / play history / gains.
struct PlayerOverlayPanel: View {
    let store: MatchStore
    @State private var hoveredCardID: String?

    var body: some View {
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

        OverlayPanelShell(
            title: "己方牌库",
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

            OverlayScrollView {
                zoneGroup(
                    "牌库中",
                    tint: .goldSoft,
                    total: mergedFriendlyStats?.deckCount,
                    cards: match.playerRemainingCards.sorted {
                        $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
                    },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    animated: true,
                    trailing: { card in
                        // 洗入的外来牌与卡组原有的 30 张区分标注
                        var parts: [String] = []
                        if card.origin != .original { parts.append("洗入") }
                        if card.copies > 1 { parts.append("×\(card.copies)") }
                        return parts.isEmpty ? nil : parts.joined(separator: " ")
                    }
                )
                zoneGroup(
                    "手牌中",
                    tint: .mintSoft,
                    total: mergedFriendlyStats?.handCount,
                    cards: store.playerHandCardsResolved.sorted {
                        $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
                    },
                    store: store,
                    hoveredCardID: $hoveredCardID,
                    animated: true
                )
                zoneGroup(
                    "已打出",
                    tint: .mistSoft,
                    cards: match.playerPlayedCards.reversed(),
                    store: store,
                    hoveredCardID: $hoveredCardID
                )
            }
        }
    }

    /// "对阵 恶魔猎手 66.7% 2/1" from the local history of this exact deck.
    @ViewBuilder
    private func winrateLine(_ match: MatchRecord) -> some View {
        let stats = store.history.stats(againstClass: match.opponentClass, deckID: match.playerDeckID)
        if stats.wins + stats.losses > 0 {
            HStack(spacing: 6) {
                Text("对阵 \(match.opponentClass)")
                    .foregroundStyle(Color.mistSoft)
                Text("\(Int(stats.winRate * 100))%")
                    .foregroundStyle(stats.winRate >= 0.5 ? Color.mintSoft : Color.goldSoft)
                Text("\(stats.wins)/\(stats.losses)")
                    .foregroundStyle(Color.mistSoft)
                Spacer()
            }
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.lineSoft, lineWidth: 1)
            )
        }
    }
}

// MARK: - Grouping

private func OverlayScrollView(@ViewBuilder content: () -> some View) -> some View {
    ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 10) {
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
    animated: Bool = false,
    trailing: ((TrackedCard) -> String?)? = nil
) -> some View {
    let revealed = cards.reduce(0) { $0 + $1.copies }
    let unknown = max((total ?? revealed) - revealed, 0)
    OverlaySection(title: title, count: revealed + unknown, tint: tint) {
        if cards.isEmpty && unknown == 0 {
            OverlayEmpty(text: "暂无")
        } else {
            if animated {
                // Stable rowKey identity lets SwiftUI diff snapshots (fresh
                // UUIDs every poll would rebuild the list wholesale): cards
                // entering the deck slide in from the top, cards leaving
                // (drawn/played) slide down toward the hand section.
                ForEach(cards, id: \.rowKey) { card in
                    OverlayCardRow(card: card, trailing: (trailing ?? zoneTrailing)(card), store: store, hoveredCardID: hoveredCardID)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
                .animation(.spring(response: 0.35, dampingFraction: 1.0),
                           value: cards.map { "\($0.rowKey)#\($0.copies)" })
            } else {
                ForEach(cards) { card in
                    OverlayCardRow(card: card, trailing: (trailing ?? zoneTrailing)(card), store: store, hoveredCardID: hoveredCardID)
                }
            }
            if unknown > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.mistSoft)
                        .frame(width: 19, height: 19)
                        .background(Color.white.opacity(0.06), in: Circle())
                    Text("未知卡牌")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mistSoft)
                    Spacer()
                    Text("×\(unknown)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.mistSoft)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.inkDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.lineSoft, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
            }
        }
    }
}

private func zoneTrailing(_ card: TrackedCard) -> String? {
    if card.playedTurn > 0 {
        return "回合 \(card.playedTurn)"
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
        let outcome = previous.result == .win ? "胜" : previous.result == .loss ? "负" : "平"
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .bold))
            Text("再遇 \(previous.startedAt.formatted(.dateTime.month().day()))：你\(outcome)")
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
            OverlaySection(title: "上次", count: cards.reduce(0) { $0 + $1.copies }, tint: .mistSoft) {
                ForEach(cards, id: \.rowKey) { card in
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
            OverlaySection(title: "奥秘 ×\(count)", count: pool.count, tint: .goldSoft) {
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
                            .foregroundStyle(triggered ? Color.mistSoft.opacity(0.7) : .white)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .kerning(-0.2)
                        .foregroundStyle(.white)
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
                    .background(Color.white.opacity(0.06), in: Capsule())
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
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.inkDeep.opacity(store.overlayBackgroundOpacity), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .animation(.spring(response: 0.3, dampingFraction: 1.0), value: hoveredCardID)
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

    private static let turnLength: TimeInterval = 75

    var body: some View {
        HStack(spacing: 10) {
            item("攻", stats?.boardATK, tint: .goldSoft)
            item(
                "血",
                stats?.currentHealth,
                tint: healthThreatened ? Color(red: 0.9, green: 0.25, blue: 0.2) : .mintSoft,
                suffix: healthThreatened ? " 💀" : nil
            )
            item("手", stats?.handCount, tint: .mistSoft)
            item(
                "库",
                stats?.deckCount,
                tint: (stats?.deckCount ?? 99) <= 3 ? Color(red: 0.9, green: 0.6, blue: 0.2) : .mistSoft,
                suffix: (stats?.deckCount ?? 99) <= 3 ? " ⚠" : nil
            )
            if let lethal {
                item("杀", lethal, tint: Color(red: 0.9, green: 0.25, blue: 0.2))
            }
            Spacer()
            if showsCountdown {
                clock
            }
        }
        .font(.system(size: 11, weight: .bold).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func item(_ label: String, _ value: Int?, tint: Color, suffix: String? = nil) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tint)
            Text((value.map(String.init) ?? "—") + (suffix ?? "")).foregroundStyle(.white)
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
    @State private var isExpanded = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: 12)
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("(\(count))")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: count)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
                )
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

    private var lookupID: String {
        card.cardID ?? card.name
    }

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.vertical, 4)
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
            Color.inkDeep.opacity(0.5)
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

    var body: some View {
        HStack(spacing: 6) {
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

private extension Color {
    static let inkDeep = Color(red: 8 / 255, green: 14 / 255, blue: 20 / 255)
    static let goldSoft = Color(red: 224 / 255, green: 176 / 255, blue: 96 / 255)
    static let mintSoft = Color(red: 112 / 255, green: 206 / 255, blue: 176 / 255)
    static let mistSoft = Color(red: 158 / 255, green: 176 / 255, blue: 188 / 255)
    static let lineSoft = Color(red: 126 / 255, green: 154 / 255, blue: 168 / 255).opacity(0.38)
}
