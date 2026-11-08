import SwiftUI
import HearthstoneCore

/// Main window: the deck center. Live in-game data lives in the two overlay
/// floaters; this surface is for decks, win rates and match history.
struct DashboardView: View {
    let store: MatchStore
    @State private var selectedDeckID: Int?
    @State private var expandedMatchID: UUID?
    @State private var hoveredCardID: String?
    @State private var filters = DeckCardFilters()
    @State private var showsMoreFilters = true
    @State private var showsCollection = true
    @State private var isStandardFormat = true

    /// Multi-dimension card filters (dimensions AND together, values OR).
    struct DeckCardFilters: Equatable {
        var types: Set<String> = []
        var rarities: Set<String> = []
        var costs: Set<Int> = []
        var mechanics: Set<String> = []
        var origins: Set<String> = []
        var races: Set<String> = []

        var isActive: Bool {
            !types.isEmpty || !rarities.isEmpty || !costs.isEmpty
                || !mechanics.isEmpty || !origins.isEmpty || !races.isEmpty
        }

        static let rarityNames: [String: String] = [
            "COMMON": "普通", "RARE": "稀有", "EPIC": "史诗", "LEGENDARY": "传说"
        ]
        static let raceNames: [String: String] = [
            "BEAST": "野兽", "DEMON": "恶魔", "MURLOC": "鱼人", "ELEMENTAL": "元素",
            "MECHANICAL": "机械", "PIRATE": "海盗", "TOTEM": "图腾", "QUILBOAR": "野猪人"
        ]
    }

    private var catalog: CardCatalog? { store.cardData.catalog }

    private func typeLabel(for cardID: String) -> String {
        guard let info = catalog?.info(for: cardID) else { return "其他" }
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

    private func rarityKey(for cardID: String) -> String {
        catalog?.rarity(for: cardID) ?? "COMMON"
    }

    private func rarityLabel(for cardID: String) -> String {
        Self.DeckCardFilters.rarityNames[rarityKey(for: cardID)] ?? "其他"
    }

    private func costBucket(for cardID: String) -> Int {
        min(catalog?.cost(for: cardID) ?? 0, 7)
    }

    private func originLabel(for cardID: String) -> String {
        catalog?.info(for: cardID)?.cardClass == "NEUTRAL" ? "中立" : "职业"
    }

    private func raceLabel(for cardID: String) -> String? {
        guard let race = catalog?.info(for: cardID)?.race else { return nil }
        return Self.DeckCardFilters.raceNames[race]
    }

    private func mechanicLabels(for cardID: String) -> Set<String> {
        Set(
            (catalog?.mechanics(for: cardID) ?? []).compactMap { mechanic in
                CardCatalog.mechanicDisplayNames[mechanic.rawValue]
            }
        )
    }

    private func matchesFilters(_ cardID: String) -> Bool {
        if !filters.types.isEmpty && !filters.types.contains(typeLabel(for: cardID)) { return false }
        if !filters.rarities.isEmpty && !filters.rarities.contains(rarityLabel(for: cardID)) { return false }
        if !filters.costs.isEmpty && !filters.costs.contains(costBucket(for: cardID)) { return false }
        if !filters.mechanics.isEmpty && filters.mechanics.isDisjoint(with: mechanicLabels(for: cardID)) { return false }
        if !filters.origins.isEmpty && !filters.origins.contains(originLabel(for: cardID)) { return false }
        if !filters.races.isEmpty {
            guard let label = raceLabel(for: cardID), filters.races.contains(label) else { return false }
        }
        return true
    }

    private func filteredCards(_ deck: DeckLibraryStore.DeckSummary) -> [(cardID: String, count: Int)] {
        deck.cards.filter { matchesFilters($0.cardID) }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.ink, Color(red: 10 / 255, green: 16 / 255, blue: 22 / 255)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                deckSidebar
                Divider().overlay(Color.line)
                detailArea
            }
        }
        .frame(minWidth: 1_020, minHeight: 660)
        .onAppear {
            if selectedDeckID == nil {
                selectedDeckID = store.deckLibrary.decks.first?.id
            }
        }
        .onChange(of: selectedDeckID) { _, _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                filters = DeckCardFilters()
            }
        }
        // 卡组列表在元数据解析完成后才首次非空;出现后自动选中第一副,
        // 否则 onAppear 那次(列表还空着)会把选中态永远留成 nil。
        .onChange(of: store.deckLibrary.decks.first?.id) { _, newValue in
            if selectedDeckID == nil {
                selectedDeckID = newValue
            }
        }
    }

    // MARK: - Sidebar

    private var deckSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("炉石助手")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                memoryBadge
                pipelineDot
            }
            .padding(20)

            Picker("", selection: $isStandardFormat) {
                Text("标准").tag(true)
                Text("狂野").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // 全卡入口
            Button {
                showsCollection = true
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(colors: [Color.gold, Color.gold.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 32, height: 24)
                        .overlay(
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.ink)
                        )
                    Text("卡牌图鉴")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showsCollection ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.mist)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(showsCollection ? Color.panel : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(showsCollection ? Color.gold.opacity(0.6) : .clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Text("我的卡组")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.mist)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.deckLibrary.decks.isEmpty {
                        Text("启动炉石并登录一次后，卡组会自动同步到这里")
                            .font(.caption)
                            .foregroundStyle(Color.mist)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(formatGroupedDecks, id: \.0) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.0)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.mist.opacity(0.9))
                                    .padding(.horizontal, 8)
                                ForEach(group.1) { deck in
                                    deckRow(deck)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()
            settingsSection
        }
        .frame(width: 264)
        .background(Color.inkLift.opacity(0.5))
    }

    /// Decks grouped by class, filtered by the selected format.
    private var formatGroupedDecks: [(String, [DeckLibraryStore.DeckSummary])] {
        let filtered = store.deckLibrary.decks.filter {
            isStandardFormat ? $0.formatName == "标准" : $0.formatName != "标准"
        }
        let grouped = Dictionary(grouping: filtered, by: \.className)
        return grouped
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    private func deckRow(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let stats = store.history.stats(deckID: deck.id)
        let selected = selectedDeckID == deck.id
        let classTint = Self.classColor(deck.className)

        return Button {
            selectedDeckID = deck.id
            showsCollection = false
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [classTint, classTint.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 24)
                    .overlay(
                        Text(deck.className.prefix(1))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    )
                    .shadow(color: classTint.opacity(0.5), radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(deck.formatName) · \(deck.className) · \(deck.cardCount) 张")
                        .font(.caption2)
                        .foregroundStyle(Color.mist)
                }
                Spacer()
                if stats.games > 0 {
                    Text("\(Int(stats.winRate * 100))%")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(stats.winRate >= 0.5 ? Color.mint : Color.mist)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.panel : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.gold.opacity(0.6) : .clear, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.gold)
                        .frame(width: 3, height: 28)
                        .offset(x: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Class colors for deck badges and title accents.
    private static func classColor(_ name: String) -> Color {
        switch name {
        case "战士": Color(red: 0.72, green: 0.21, blue: 0.17)
        case "法师": Color(red: 0.25, green: 0.66, blue: 0.96)
        case "猎人": Color(red: 0.30, green: 0.55, blue: 0.17)
        case "德鲁伊": Color(red: 0.42, green: 0.28, blue: 0.20)
        case "萨满祭司": Color(red: 0.14, green: 0.35, blue: 0.66)
        case "术士": Color(red: 0.49, green: 0.21, blue: 0.59)
        case "牧师": Color(red: 0.85, green: 0.85, blue: 0.9)
        case "圣骑士": Color(red: 0.72, green: 0.64, blue: 0.27)
        case "潜行者": Color(red: 0.35, green: 0.33, blue: 0.30)
        case "死亡骑士": Color(red: 0.20, green: 0.55, blue: 0.55)
        case "恶魔猎手": Color(red: 0.55, green: 0.13, blue: 0.25)
        default: Color.mist
        }
    }

    /// Live memory-read badge: setup stage, or zone counts while in a match.
    @ViewBuilder
    private var memoryBadge: some View {
        let stage = store.memory.stage
        if store.memory.inMatch, let c = store.memory.counts {
            let text = "手 \(c.friendlyHand.map(String.init) ?? "-")/\(c.opponentHand.map(String.init) ?? "-") 库 \(c.friendlyDeck.map(String.init) ?? "-")/\(c.opponentDeck.map(String.init) ?? "-") 场 \(c.friendlyBoard.map(String.init) ?? "-")/\(c.opponentBoard.map(String.init) ?? "-")"
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gold.opacity(0.14), in: Capsule())
                .help("内存直读（己方/对手）")
        } else {
            Text(stage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.mist)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.mist.opacity(0.12), in: Capsule())
        }
    }

    private var pipelineDot: some View {
        let text: String
        let tint: Color
        switch store.status {
        case .missingLogConfig: text = "日志未启用"; tint = .mist
        case .notRunning: text = "未登录"; tint = .mist
        case .loggedIn: text = "已登录"; tint = .mint
        case .live: text = "游戏中"; tint = .gold
        case .finished: text = "本局已结束"; tint = .gold
        }
        return HStack(spacing: 6) {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
            if case .missingLogConfig = store.status {
                Button("启用日志") {
                    guard !HearthstoneLogLocator.isLogConfigPresent() else { return }
                    try? HearthstoneLogLocator.writeLogConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Color.line)
            Text("助手行为")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.mist)

            Toggle("登录 macOS 时自动启动", isOn: Binding(
                get: { store.lifecycle.launchesAtLogin },
                set: { store.lifecycle.setLaunchesAtLogin($0) }
            ))
            Toggle("炉石退出时自动退出助手", isOn: Binding(
                get: { store.lifecycle.quitsWithHearthstone },
                set: { store.lifecycle.setQuitsWithHearthstone($0) }
            ))
            Toggle("浮窗鼠标穿透（不挡游戏）", isOn: Binding(
                get: { store.isOverlayPassthrough },
                set: { store.isOverlayPassthrough = $0 }
            ))

            Picker("浮窗透明度", selection: Binding(
                get: { store.overlayOpacityLevel },
                set: { store.overlayOpacityLevel = $0 }
            )) {
                Text("低").tag(0)
                Text("中").tag(1)
                Text("高").tag(2)
            }
            .pickerStyle(.segmented)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.9))
        .padding(16)
    }

    // MARK: - Detail

    private var detailArea: some View {
        Group {
            if showsCollection {
                CollectionBrowser(store: store, isStandard: isStandardFormat)
            } else if let deck = store.deckLibrary.decks.first(where: { $0.id == selectedDeckID }) {
                deckDetail(deck)
            } else {
                emptyDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(Color.mist)
            Text("选择一个卡组查看战绩")
                .font(.headline)
                .foregroundStyle(.white)
            Text("卡组列表从炉石客户端日志自动同步；打完对局后这里会出现胜率统计")
                .font(.caption)
                .foregroundStyle(Color.mist)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func deckDetail(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let overall = store.history.stats(deckID: deck.id)

        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [Self.classColor(deck.className), Self.classColor(deck.className).opacity(0.5)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 4, height: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(deck.name)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("\(deck.className) · \(deck.cardCount) 张构筑 · \(deck.formatName)")
                            .font(.subheadline)
                            .foregroundStyle(Color.mist)
                    }
                    Spacer()
                    Button {
                        guard !deck.code.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(deck.code, forType: .string)
                    } label: {
                        Label("复制卡组代码", systemImage: "doc.on.doc")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.gold)
                    .disabled(deck.code.isEmpty)
                    }

                    statsHeader(overall)

                    classBreakdown(deck)

                    mulliganStats(deck)

                    recentMatches(deck)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Color.line)

            deckCardList(deck)
        }
    }

    private func statsHeader(_ stats: MatchHistoryStore.DeckStats) -> some View {
        HStack(spacing: 24) {
            winRateRing(stats)
            statBlock("总场次", "\(stats.games)")
            statBlock("胜 / 负 / 平", "\(stats.wins) / \(stats.losses) / \(stats.ties)")
            Spacer()
        }
        .padding(20)
        .background(Color.inkLift, in: RoundedRectangle(cornerRadius: 16))
    }

    /// The win-rate ring is the deck page's visual anchor.
    private func winRateRing(_ stats: MatchHistoryStore.DeckStats) -> some View {
        let rate = stats.games > 0 ? stats.winRate : 0

        return ZStack {
            Circle()
                .stroke(Color.line, lineWidth: 6)
            Circle()
                .trim(from: 0, to: rate)
                .stroke(
                    LinearGradient(
                        colors: [Color.mint, Color.mint.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: rate)
            VStack(spacing: 0) {
                Text(stats.games > 0 ? "\(Int(rate * 100))%" : "—")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("胜率")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mist)
            }
        }
        .frame(width: 64, height: 64)
    }

    private func statBlock(_ label: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.mist)
        }
    }

    /// 起手留牌胜率：本地历史中每张牌"留了 vs 换掉"的场次与胜率。
    private func mulliganStats(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let matches = store.history.entries.filter {
            $0.deckID == deck.id && $0.mulliganKept != nil
        }

        var byCard: [String: MulliganRow] = [:]
        for entry in matches {
            let won = entry.result == .win
            for card in entry.mulliganKept ?? [] {
                var row = byCard[card] ?? MulliganRow(name: card)
                row.kept += 1
                if won { row.keptWins += 1 }
                byCard[card] = row
            }
            for card in entry.mulliganDiscarded ?? [] {
                var row = byCard[card] ?? MulliganRow(name: card)
                row.discarded += 1
                if won { row.discardedWins += 1 }
                byCard[card] = row
            }
        }

        let rows = byCard.values
            .filter { $0.kept >= 2 || $0.discarded >= 2 }
            .sorted {
                min($0.kept, $0.discarded) > min($1.kept, $1.discarded)
            }

        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("起手留牌（样本 \(matches.count) 局）")
                        .font(.headline)
                        .foregroundStyle(.white)
                    ForEach(rows.prefix(10), id: \.name) { row in
                        mulliganRowView(row, deck: deck)
                    }
                    Text("样本越多越可靠；同一张卡两个数字差距大 = 留牌倾向有信号")
                        .font(.caption2)
                        .foregroundStyle(Color.mist.opacity(0.7))
                }
            }
        }
    }

    private func mulliganRowView(_ row: MulliganRow, deck: DeckLibraryStore.DeckSummary) -> some View {
        let keptRate = row.kept > 0 ? Double(row.keptWins) / Double(row.kept) : 0
        let dropRate = row.discarded > 0 ? Double(row.discardedWins) / Double(row.discarded) : 0
        let cardID = deck.cards.first { catalog?.displayName(for: $0.cardID) == row.name }?.cardID
            ?? catalog?.cards.keys.first { catalog?.displayName(for: $0) == row.name }

        return HStack(spacing: 10) {
            Text(catalog?.displayName(for: cardID ?? "") ?? row.name)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            if row.kept > 0 {
                statPair("留 \(row.kept)", keptRate)
            }
            if row.discarded > 0 {
                statPair("换 \(row.discarded)", dropRate)
            }
        }
        .padding(.vertical, 2)
    }

    private func statPair(_ label: String, _ rate: Double) -> some View {
        Text("\(label) · \(Int(rate * 100))%")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(rate >= 0.5 ? Color.mint : Color.gold)
    }

    private func classBreakdown(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let classNames = orderedClasses(deck)

        return VStack(alignment: .leading, spacing: 12) {
            Text("面对各职业")
                .font(.headline)
                .foregroundStyle(.white)
            if classNames.isEmpty {
                Text("暂无对局数据")
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(classNames, id: \.self) { className in
                    classRow(className: className, deckID: deck.id)
                }
            }
        }
    }

    private func orderedClasses(_ deck: DeckLibraryStore.DeckSummary) -> [String] {
        var counts: [String: Int] = [:]
        for entry in store.history.entries where entry.deckID == deck.id {
            counts[entry.opponentClass, default: 0] += 1
        }
        return counts.keys.sorted { counts[$0]! > counts[$1]! }
    }

    private func classRow(className: String, deckID: Int) -> some View {
        let stats = store.history.stats(againstClass: className, deckID: deckID)
        let total = max(stats.wins + stats.losses, 1)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(className)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(stats.wins)胜 \(stats.losses)负")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.mist)
                Text(stats.wins + stats.losses > 0 ? "\(Int(stats.winRate * 100))%" : "—")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(stats.winRate >= 0.5 ? Color.mint : Color.gold)
                    .frame(width: 44, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.line)
                    Capsule()
                        .fill(Color.mint.opacity(0.75))
                        .frame(width: proxy.size.width * CGFloat(stats.wins) / CGFloat(total))
                    Capsule()
                        .fill(Color.gold.opacity(0.55))
                        .frame(width: proxy.size.width * CGFloat(stats.losses) / CGFloat(total))
                        .offset(x: proxy.size.width * CGFloat(stats.wins) / CGFloat(total))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private func recentMatches(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let matches = store.history.recentMatches(deckID: deck.id)

        return VStack(alignment: .leading, spacing: 12) {
            Text("最近对局")
                .font(.headline)
                .foregroundStyle(.white)
            if matches.isEmpty {
                Text("还没有已完成的对局")
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(matches) { entry in
                    matchRow(entry)
                }
            }
        }
    }

    private func matchRow(_ entry: MatchHistoryEntry) -> some View {
        let expanded = expandedMatchID == entry.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedMatchID = expanded ? nil : entry.id
                }
            } label: {
                HStack(spacing: 12) {
                    Text(entry.result == .win ? "胜" : entry.result == .loss ? "负" : "平")
                        .font(.caption.bold())
                        .foregroundStyle(Color.ink)
                        .frame(width: 24, height: 24)
                        .background(
                            entry.result == .win ? Color.mint :
                                entry.result == .loss ? Color.gold : Color.mist,
                            in: Circle()
                        )
                    Text("对阵 \(localizedOpponentClass(entry.opponentClass))")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Text(entry.deckName)
                        .font(.caption2)
                        .foregroundStyle(Color.mist)
                        .lineLimit(1)
                    if let format = entry.format {
                        Text(format)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.mist.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.mist.opacity(0.12), in: Capsule())
                    }
                    if entry.integrity != .complete {
                        Text("部分记录")
                            .font(.caption2)
                            .foregroundStyle(Color.mist)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.mist.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(entry.startedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.mist)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.mist)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                matchDetail(entry)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(expanded ? Color.inkLift : Color.clear)
        )
    }

    /// Inline post-game review: everything both sides showed this match.
    private func matchDetail(_ entry: MatchHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CardOrigin.allCases, id: \.self) { origin in
                let cards = (entry.opponentCards ?? [])
                    .filter { $0.origin == origin && !$0.isBoardOnly }
                    .sorted { $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost }
                if !cards.isEmpty {
                    detailGroup("对手 · \(origin.title)", tint: origin == .original ? .mint : .mist) {
                        ForEach(cards) { card in
                            detailCardRow(card, trailing: "回合 \(card.playedTurn)")
                        }
                    }
                }
            }

            let played = entry.playerPlayedCards ?? []
            if !played.isEmpty {
                detailGroup("己方 · 已打出", tint: .gold) {
                    ForEach(played) { card in
                        detailCardRow(card, trailing: "回合 \(card.playedTurn)")
                    }
                }
            }

            let remaining = (entry.playerRemainingCards ?? []).sorted {
                $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
            }
            if !remaining.isEmpty {
                detailGroup("己方 · 终局牌库", tint: .gold) {
                    ForEach(remaining) { card in
                        detailCardRow(card, trailing: "×\(card.copies)")
                    }
                }
            }

            if (entry.opponentCards ?? []).isEmpty && (entry.playerPlayedCards ?? []).isEmpty {
                Text("本局没有保存卡牌快照")
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            }

            turnTimeline(entry)
            opponentDeckExport(entry)
        }
        .padding(.top, 6)
    }

    /// 逐回合时间线：每回合双方打出的牌。
    @ViewBuilder
    private func turnTimeline(_ entry: MatchHistoryEntry) -> some View {
        if let turns = entry.turns, !turns.isEmpty {
            detailGroup("回合时间线", tint: .gold) {
                ForEach(turns, id: \.turn) { turn in
                    HStack(alignment: .top, spacing: 10) {
                        Text("T\(turn.turn)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color.gold)
                            .frame(width: 26, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            if !turn.friendlyPlays.isEmpty {
                                turnPlayRow("己", .mint, turn.friendlyPlays)
                            }
                            if !turn.opponentPlays.isEmpty {
                                turnPlayRow("敌", .gold, turn.opponentPlays)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func turnPlayRow(_ side: String, _ tint: Color, _ cards: [TrackedCard]) -> some View {
        let catalog = store.cardData.catalog
        return HStack(spacing: 6) {
            Text(side)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(
                cards.map { card in
                    let id = card.cardID ?? card.name
                    let name = catalog?.displayName(for: id) ?? card.name
                    let cost = catalog?.cost(for: id) ?? card.cost
                    return "[\(cost)]\(name)\(card.copies > 1 ? "×\(card.copies)" : "")"
                }
                .joined(separator: "  ")
            )
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(2)
        }
    }

    /// 对手 30 张原始牌还原完成 → 一键复制 deckstring。
    @ViewBuilder
    private func opponentDeckExport(_ entry: MatchHistoryEntry) -> some View {
        let originals = (entry.opponentCards ?? []).filter {
            $0.origin == .original && !$0.isBoardOnly
        }
        let total = originals.reduce(0) { $0 + $1.copies }
        if total >= 30, let catalog = store.cardData.catalog {
            let entries = originals.flatMap { card -> [(dbfID: Int, count: Int)] in
                guard let cardID = card.cardID,
                      let dbf = catalog.info(for: cardID)?.dbfId
                else { return [] }
                return [(dbf, card.copies)]
            }
            if entries.reduce(0, { $0 + $1.count }) >= 30,
               let heroDbfID = opponentHeroDbfID(entry, catalog: catalog) {
                Button {
                    let code = DeckCode.encode(
                        heroDbfID: heroDbfID,
                        cards: entries,
                        format: deckFormatCode(entry.format)
                    )
                    guard !code.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("复制对手卡组代码", systemImage: "doc.on.doc")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gold)
            }
        }
    }

    /// This match's hero, not a stand-in. A localized class name has no dbfId.
    private func opponentHeroDbfID(_ entry: MatchHistoryEntry, catalog: CardCatalog) -> Int? {
        let cardID = entry.opponentHeroCardID ?? entry.opponentClass
        guard catalog.classDisplayName(forHeroCardID: cardID) != nil else { return nil }
        return catalog.info(for: cardID)?.dbfId
    }

    private func deckFormatCode(_ format: String?) -> Int {
        switch format {
        case "狂野": 1
        case "经典": 3
        case "幻变": 4
        default: 2
        }
    }

    private func detailGroup<Content: View>(
        _ title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Spacer()
            }
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func detailCardRow(_ card: TrackedCard, trailing: String) -> some View {
        let lookupID = card.cardID ?? card.name
        // localize at display time: legacy history entries may store raw IDs
        let displayName = store.cardData.catalog?.displayName(for: lookupID) ?? card.name
        let displayCost = store.cardData.catalog?.cost(for: lookupID) ?? card.cost
        let rarityTint = Self.rarityColor(store.cardData.catalog?.rarity(for: lookupID))
        let isSource = hoveredCardID == lookupID
        let isCombo = hoveredCardID != nil && hoveredCardID != lookupID
            && (store.cardData.catalog?.hasCombo(hoveredCardID!, with: lookupID) ?? false)

        return HStack(spacing: 8) {
            Text("\(displayCost)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(rarityTint, in: Circle())
            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text(trailing)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.mist)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if let strip = store.cardImages.strip(for: lookupID) {
                Image(nsImage: strip)
                    .resizable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(Color.black.opacity(isCombo ? 0.1 : 0.34))
            } else {
                Color.inkDeep.opacity(0.4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSource ? Color.white : (isCombo ? Color.gold : .clear),
                    lineWidth: isSource || isCombo ? 1.5 : 0
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            hoveredCardID = hovering ? lookupID : nil
        }
        .onAppear {
            store.cardImages.prefetch([lookupID])
        }
    }

    private func deckCardList(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let visible = filteredCards(deck)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                if filters.isActive {
                    Button("重置筛选") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                            filters = DeckCardFilters()
                        }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.gold)
                    .buttonStyle(.plain)
                }
            }

            filterChips(deck)

            if !deck.curve.isEmpty {
                ManaCurveView(curve: deck.curve, selection: $filters.costs)
            }

            Divider().overlay(Color.line)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if deck.cards.isEmpty {
                        Text("卡牌数据未就绪")
                            .font(.caption)
                            .foregroundStyle(Color.mist)
                            .padding(16)
                    } else if visible.isEmpty {
                        Text("没有符合条件的卡")
                            .font(.caption)
                            .foregroundStyle(Color.mist)
                            .padding(16)
                    } else {
                        ForEach(visible, id: \.cardID) { card in
                            deckCardRow(cardID: card.cardID, count: card.count, hoveredCardID: $hoveredCardID)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 280)
        .overlay(alignment: .trailing) {
            hoverCardPreview
        }
    }

    // MARK: - Filter chips

    private func filterChips(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let cards = deck.cards

        let typeCounts = Dictionary(grouping: cards, by: { typeLabel(for: $0.cardID) })
            .mapValues { $0.reduce(0) { $0 + $1.count } }
        let rarityCounts = Dictionary(grouping: cards, by: { rarityLabel(for: $0.cardID) })
            .mapValues { $0.reduce(0) { $0 + $1.count } }
        let mechanicCounts = Dictionary(grouping: cards.flatMap { entry in
            mechanicLabels(for: entry.cardID).map { ($0, entry.count) }
        }, by: \.0).mapValues { $0.reduce(0) { $0 + $1.1 } }
        let originCounts = Dictionary(grouping: cards, by: { originLabel(for: $0.cardID) })
            .mapValues { $0.reduce(0) { $0 + $1.count } }
        let raceCounts = Dictionary(grouping: cards.compactMap { entry -> (String, Int)? in
            guard let label = raceLabel(for: entry.cardID) else { return nil }
            return (label, entry.count)
        }, by: \.0).mapValues { $0.reduce(0) { $0 + $1.1 } }

        return VStack(alignment: .leading, spacing: 6) {
            chipRow(
                values: ["随从", "法术", "武器", "任务", "英雄", "地标"]
                    .filter { (typeCounts[$0] ?? 0) > 0 }
                    .map { ($0, typeCounts[$0]!) },
                selection: $filters.types,
                tint: .mint
            )
            chipRow(
                values: ["传说", "史诗", "稀有", "普通"]
                    .filter { (rarityCounts[$0] ?? 0) > 0 }
                    .map { ($0, rarityCounts[$0]!) },
                selection: $filters.rarities,
                tint: .gold
            )

            DisclosureGroup(isExpanded: $showsMoreFilters) {
                VStack(alignment: .leading, spacing: 6) {
                    chipRow(
                        values: mechanicCounts
                            .filter { $0.value > 0 }
                            .map { ($0.key, $0.value) }
                            .sorted { $0.1 > $1.1 },
                        selection: $filters.mechanics,
                        tint: .mint
                    )
                    chipRow(
                        values: [("中立", originCounts["中立"] ?? 0), ("职业", originCounts["职业"] ?? 0)]
                            .filter { $0.1 > 0 },
                        selection: $filters.origins,
                        tint: .mist
                    )
                    if !raceCounts.isEmpty {
                        chipRow(
                            values: raceCounts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 },
                            selection: $filters.races,
                            tint: .gold
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("更多筛选（机制 / 归属 / 属性）")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.mist)
            }
            .tint(Color.gold)
        }
    }

    private func chipRow(
        values: [(String, Int)],
        selection: Binding<Set<String>>,
        tint: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.0) { value in
                    FilterChip(
                        label: value.0,
                        count: value.1,
                        tint: tint,
                        isOn: selection.wrappedValue.contains(value.0)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                            if selection.wrappedValue.contains(value.0) {
                                selection.wrappedValue.remove(value.0)
                            } else {
                                selection.wrappedValue.insert(value.0)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct FilterChip: View {
        let label: String
        let count: Int
        let tint: Color
        let isOn: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isOn ? 1 : 0.82))
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(isOn ? tint : Color.mist)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isOn ? tint.opacity(0.28) : Color.inkDeep.opacity(0.55))
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? tint.opacity(0.8) : Color.line.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Full-card render for the currently hovered row (deck list & match detail).
    @ViewBuilder
    private var hoverCardPreview: some View {
        if
            let cardID = hoveredCardID,
            let image = store.cardImages.fullImage(for: cardID)
        {
            VStack(alignment: .trailing, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 232, height: 232 * 388.0 / 256.0)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 4)
                    .allowsHitTesting(false)
                if let comboNote {
                    Text(comboNote)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.gold, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .padding(.trailing, 16)
        }
    }

    private var comboNote: String? {
        guard let hoveredCardID else { return nil }
        return "金色边框 = 与此卡有配合"
    }

    private func deckCardRow(
        cardID: String,
        count: Int,
        hoveredCardID: Binding<String?>
    ) -> some View {
        let cost = store.cardData.catalog?.cost(for: cardID) ?? 0
        let name = store.cardData.catalog?.displayName(for: cardID) ?? cardID
        let rarityTint = Self.rarityColor(store.cardData.catalog?.rarity(for: cardID))
        let hovered = hoveredCardID.wrappedValue
        let isSource = hovered == cardID
        let isCombo = hovered != nil && hovered != cardID
            && (store.cardData.catalog?.hasCombo(hovered!, with: cardID) ?? false)

        return HStack(spacing: 8) {
            Text("\(cost)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(rarityTint, in: Circle())
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text("×\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.mist)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if let strip = store.cardImages.strip(for: cardID) {
                Image(nsImage: strip)
                    .resizable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(Color.black.opacity(isCombo ? 0.1 : 0.34))
            } else {
                Color.inkDeep.opacity(0.5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSource ? Color.white : (isCombo ? Color.gold : .clear),
                    lineWidth: isSource || isCombo ? 1.5 : 0
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            hoveredCardID.wrappedValue = hovering ? cardID : nil
        }
        .onAppear {
            store.cardImages.prefetch([cardID])
        }
    }

    /// History entries appended before the catalog loaded store raw hero
    /// cardIDs; resolve them at display time.
    private func localizedOpponentClass(_ raw: String) -> String {
        store.cardData.catalog?.classDisplayName(forHeroCardID: raw) ?? raw
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

    // MARK: - Mana curve & type composition

    private struct ManaCurveView: View {
        let curve: [Int]
        @Binding var selection: Set<Int>

        var body: some View {
            let peak = max(curve.max() ?? 1, 1)

            return HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(curve.enumerated()), id: \.offset) { index, count in
                    let isSelected = selection.contains(index)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                            if isSelected {
                                selection.remove(index)
                            } else {
                                selection.insert(index)
                            }
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(count > 0 ? "\(count)" : "")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.gold : Color.mist)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.gold.opacity(isSelected ? 1.0 : 0.85),
                                            Color.gold.opacity(0.35),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: max(CGFloat(count) / CGFloat(peak) * 44, count > 0 ? 4 : 1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1)
                                )
                            Text(index == 7 ? "7+" : "\(index)")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.gold : Color.mist)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.inkLift, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// 起手留牌统计的一行聚合（文件级类型，ViewBuilder 闭包内不能声明类型）。
private struct MulliganRow {
    var name: String
    var kept = 0
    var keptWins = 0
    var discarded = 0
    var discardedWins = 0
}

private extension Color {
    static let ink = Color(red: 16 / 255, green: 26 / 255, blue: 33 / 255)
    static let inkLift = Color(red: 23 / 255, green: 38 / 255, blue: 48 / 255)
    static let panel = Color(red: 29 / 255, green: 48 / 255, blue: 60 / 255)
    static let line = Color(red: 83 / 255, green: 111 / 255, blue: 125 / 255).opacity(0.45)
    static let gold = Color(red: 214 / 255, green: 168 / 255, blue: 93 / 255)
    static let mint = Color(red: 105 / 255, green: 200 / 255, blue: 176 / 255)
    static let mist = Color(red: 142 / 255, green: 162 / 255, blue: 176 / 255)
    static let inkDeep = Color(red: 14 / 255, green: 22 / 255, blue: 29 / 255)
}
