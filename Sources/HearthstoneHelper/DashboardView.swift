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
    @State private var showsSettings = false
    @State private var selectedImportID: UUID?
    @State private var importDraft = ""
    @State private var historyQuery = ""
    @State private var historyOutcome = 0
    @Environment(\.colorScheme) private var systemScheme

    private var chromeContext: HearthContext {
        store.interfaceContext(systemIsLight: systemScheme == .light, overlay: false)
    }

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
        let context = HearthChrome.install(chromeContext)
        return ZStack {
            LinearGradient(
                colors: [Color.inkTop, Color.ink, Color.inkBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .animation(HearthChrome.motion == .off ? nil : .easeInOut(duration: HearthChrome.motion == .flashy ? 0.45 : 0.22), value: context.isLight)

            RadialGradient(
                colors: [Color.gold.opacity(context.isLight ? 0.10 : 0.16), Color.gold.opacity(0.04), .clear],
                center: UnitPoint(x: 0.12, y: 0),
                startRadius: 12,
                endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                deckSidebar
                Rectangle()
                    .fill(Color.line)
                    .frame(width: 1)
                detailArea
            }
        }
        .environment(\.hearthContext, context)
        .tint(Color.gold)
        .preferredColorScheme((AppearanceChoice(rawValue: store.appearanceChoice) ?? .dark).preferredScheme)
        .frame(minWidth: 1_020, minHeight: 660)
        .onAppear {
            if selectedDeckID == nil {
                selectedDeckID = store.deckLibrary.decks.first?.id
            }
        }
        .onChange(of: selectedDeckID) { _, _ in
            HearthChrome.Motion.run {
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.gold, Color(red: 176 / 255, green: 124 / 255, blue: 58 / 255)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.onGold)
                    }
                    .frame(width: 28, height: 28)
                    .shadow(color: Color.gold.opacity(0.35), radius: 6, y: 2)

                    Text(HearthChrome.L("炉石助手", "Hearthstone"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.hearthText)
                    Spacer(minLength: 0)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        pipelineDot
                        memoryBadge
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        pipelineDot
                        memoryBadge
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Text(HearthChrome.L("格式", "Format"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.mist)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            Picker("", selection: $isStandardFormat) {
                Text(HearthChrome.L("标准", "Standard")).tag(true)
                Text(HearthChrome.L("狂野", "Wild")).tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // 全卡入口
            Button {
                HearthChrome.Motion.run {
                    showsCollection = true
                    showsSettings = false
                    selectedImportID = nil
                }
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color.gold, Color.gold.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 32, height: 24)
                        .overlay(
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.caption2.bold())
                                .foregroundStyle(Color.onGold)
                        )
                    Text(HearthChrome.L("卡牌图鉴", "Collection"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.hearthText)
                    Spacer()
                    Image(systemName: showsCollection ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.mist)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .modifier(HoverHighlight(selected: showsCollection))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text(HearthChrome.L("我的卡组", "My decks"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.mist)
                Rectangle()
                    .fill(Color.line)
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if store.deckLibrary.decks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "rectangle.stack")
                                .font(.title3)
                                .foregroundStyle(Color.gold.opacity(0.9))
                            Text(HearthChrome.L(
                                "启动炉石并登录一次后，卡组会自动同步到这里",
                                "Launch Hearthstone and log in once. Decks sync here automatically."
                            ))
                                .font(.caption)
                                .foregroundStyle(Color.mist)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.inkDeep.opacity(0.45))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.line, lineWidth: 1)
                        )
                    } else {
                        ForEach(formatGroupedDecks, id: \.0) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(HearthChrome.phrase(group.0))
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
                .padding(.bottom, 12)
                .animation(HearthChrome.Motion.optional(.spring(response: 0.36, dampingFraction: 0.86)), value: isStandardFormat)
            }

            Spacer(minLength: 0)
            importBlock
            settingsSection
        }
        .frame(width: 280)
        .background(
            LinearGradient(
                colors: [Color.inkLift.opacity(0.78), Color.ink.opacity(0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Decks grouped by class, filtered by the selected format.
    private var formatGroupedDecks: [(String, [DeckLibraryStore.DeckSummary])] {
        let filtered = store.deckLibrary.decks.filter {
            isStandardFormat ? $0.formatName == "标准" : $0.formatName != "标准"
        }
        let grouped = Dictionary(grouping: filtered, by: \.className)
        return grouped
            .map { ($0.key, $0.value.sorted { lhs, rhs in
                let left = store.deckMarks.isFavorite(lhs.id)
                let right = store.deckMarks.isFavorite(rhs.id)
                if left != right { return left && !right }
                return lhs.name < rhs.name
            }) }
            .sorted { $0.0 < $1.0 }
    }

    private func deckRow(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let stats = store.history.stats(deckID: deck.id)
        let selected = selectedDeckID == deck.id
        let classTint = Self.classColor(deck.className)

        return HStack(spacing: 4) {
            Button {
                HearthChrome.Motion.run {
                    selectedDeckID = deck.id
                    showsCollection = false
                    showsSettings = false
                    selectedImportID = nil
                }
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
                            .foregroundStyle(deck.className == "牧师" ? Color.onGold : .white)
                    )
                    .shadow(color: classTint.opacity(0.5), radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.hearthText)
                        .lineLimit(1)
                    Text("\(HearthChrome.phrase(deck.formatName)) · \(HearthChrome.phrase(deck.className)) · \(HearthChrome.L("\(deck.cardCount) 张", "\(deck.cardCount) cards"))")
                        .font(.caption2)
                        .foregroundStyle(Color.mist)
                    if !store.deckMarks.tag(for: deck.id).isEmpty {
                        Text(store.deckMarks.tag(for: deck.id))
                            .font(.caption2)
                            .foregroundStyle(Color.gold)
                            .lineLimit(1)
                    }
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
            .modifier(HoverHighlight(selected: selected))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.gold)
                        .frame(width: 3, height: 22)
                        .padding(.leading, 2)
                }
            }
        }
        .buttonStyle(.plain)
            Button {
                store.deckMarks.toggleFavorite(deck.id)
            } label: {
                Image(systemName: store.deckMarks.isFavorite(deck.id) ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(store.deckMarks.isFavorite(deck.id) ? Color.gold : Color.mist)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(HearthChrome.L("收藏", "Favorite"))
        }
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
            let text = HearthChrome.L(
                "手 \(c.friendlyHand.map(String.init) ?? "-")/\(c.opponentHand.map(String.init) ?? "-") 库 \(c.friendlyDeck.map(String.init) ?? "-")/\(c.opponentDeck.map(String.init) ?? "-") 场 \(c.friendlyBoard.map(String.init) ?? "-")/\(c.opponentBoard.map(String.init) ?? "-")",
                "H \(c.friendlyHand.map(String.init) ?? "-")/\(c.opponentHand.map(String.init) ?? "-") D \(c.friendlyDeck.map(String.init) ?? "-")/\(c.opponentDeck.map(String.init) ?? "-") B \(c.friendlyBoard.map(String.init) ?? "-")/\(c.opponentBoard.map(String.init) ?? "-")"
            )
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gold.opacity(0.14), in: Capsule())
                .help(HearthChrome.L("内存直读（己方/对手）", "Memory read (you / opponent)"))
        } else {
            Text(HearthChrome.phrase(stage))
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
        case .missingLogConfig: text = HearthChrome.L("日志未启用", "Logs off"); tint = .mist
        case .notRunning: text = HearthChrome.L("未登录", "Signed out"); tint = .mist
        case .loggedIn: text = HearthChrome.L("已登录", "Signed in"); tint = .mint
        case .live: text = HearthChrome.L("游戏中", "In game"); tint = .gold
        case .finished: text = HearthChrome.L("本局已结束", "Match over"); tint = .gold
        }
        let live = if case .live = store.status { true } else { false }
        return HStack(spacing: 6) {
            LivePulse(active: live, tint: tint)
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
            if case .missingLogConfig = store.status {
                Button(HearthChrome.L("启用日志", "Enable logs")) {
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                HearthChrome.Motion.run {
                    showsSettings = true
                    showsCollection = false
                    selectedImportID = nil
                }
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.gold)
                    Text(HearthChrome.L("设置", "Settings"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.hearthText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.mist)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .modifier(HoverHighlight(selected: showsSettings))
            }
            .buttonStyle(.plain)
            Text(HearthChrome.L(
                "外观、动效、浮窗、登录启动和快捷键",
                "Appearance, motion, overlays, login, and shortcuts"
            ))
            .font(.caption2)
            .foregroundStyle(Color.mist)
            .padding(.horizontal, 8)
        }
        .padding(12)
        .background(Color.inkDeep.opacity(0.42))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.line).frame(height: 1)
        }
    }

    private var importBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(HearthChrome.L("粘贴卡组代码", "Paste a deck code"), text: $importDraft)
                    .textFieldStyle(.roundedBorder)
                Button(HearthChrome.L("导入", "Import")) {
                    guard store.deckMarks.importCode(importDraft, catalog: store.cardData.catalog) else { return }
                    importDraft = ""
                    selectedImportID = store.deckMarks.imported.last?.id
                    showsCollection = false
                    showsSettings = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(HearthChrome.L("导出列表", "Export list")) {
                store.copyExportedDecks()
            }
            .buttonStyle(.borderless)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.gold)
            ForEach(store.deckMarks.imported) { deck in
                Button {
                    selectedImportID = deck.id
                    showsCollection = false
                    showsSettings = false
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption2)
                            .foregroundStyle(Color.gold)
                        Text(deck.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.hearthText)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func importedDetail(_ deck: ImportedDeck) -> some View {
        let cards = store.deckMarks.resolvedCards(deck, catalog: store.cardData.catalog)
        return VStack(alignment: .leading, spacing: 16) {
            Text(deck.name)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(Color.hearthText)
            Text(HearthChrome.L(
                "这是本地导入的卡组代码，只供查看和复制，不计入胜率，也不参与对局牌库还原。",
                "This deck code is stored locally for viewing and copying. It is not part of your win rate or in-match deck tracking."
            ))
            .font(.caption)
            .foregroundStyle(Color.mist)
            HStack {
                goldButton(HearthChrome.L("复制卡组代码", "Copy deck code"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deck.code, forType: .string)
                }
                Button(HearthChrome.L("删除", "Delete")) {
                    store.deckMarks.removeImported(deck.id)
                    selectedImportID = nil
                }
                .buttonStyle(.bordered)
            }
            if cards.isEmpty {
                Text(HearthChrome.L("卡牌数据未就绪，或这段代码解不出来。", "Card data isn't ready, or this code could not be read."))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(cards, id: \.cardID) { card in
                    deckCardRow(cardID: card.cardID, count: card.count, hoveredCardID: $hoveredCardID)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Detail

    private var detailArea: some View {
        Group {
            if showsSettings {
            HelperSettingsPane(store: store)
                .transition(.opacity.combined(with: .offset(y: 12)))
        } else if showsCollection {
                VStack(spacing: 0) {
                    RankTrajectoryCard(store: store)
                    CollectionBrowser(store: store, isStandard: isStandardFormat)
                }
                    .transition(.opacity.combined(with: .offset(y: 12)))
            } else if let imported = store.deckMarks.imported.first(where: { $0.id == selectedImportID }) {
                importedDetail(imported)
                    .id(imported.id)
                    .transition(.opacity.combined(with: .offset(x: 22)))
            } else if let deck = store.deckLibrary.decks.first(where: { $0.id == selectedDeckID }) {
                deckDetail(deck)
                    .id(deck.id)
                    .transition(.opacity.combined(with: .offset(x: 22)))
            } else {
                emptyDetail
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.gold.opacity(0.1))
                    .frame(width: 88, height: 88)
                Circle()
                    .strokeBorder(Color.gold.opacity(0.38), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.gold)
            }
            Text(HearthChrome.L("选择一个卡组查看战绩", "Select a deck to see its record"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.hearthText)
            Text(HearthChrome.L(
                "卡组列表从炉石客户端日志自动同步；打完对局后这里会出现胜率统计",
                "Decks sync from the Hearthstone log. Win rate shows up after you finish games."
            ))
                .font(.subheadline)
                .foregroundStyle(Color.mist)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softAppear()
    }

    private func deckDetail(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let overall = store.history.stats(deckID: deck.id)

        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Self.classColor(deck.className), Self.classColor(deck.className).opacity(0.45)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 5, height: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(deck.name)
                                .font(.system(size: 27, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.hearthText)
                            HStack(spacing: 6) {
                                metaPill(HearthChrome.phrase(deck.className), tint: Self.classColor(deck.className))
                                metaPill(HearthChrome.phrase(deck.formatName), tint: Color.mist)
                                metaPill(HearthChrome.L("\(deck.cardCount) 张", "\(deck.cardCount) cards"), tint: Color.gold)
                            }
                        }
                        Spacer()
                        goldButton(HearthChrome.L("复制卡组代码", "Copy deck code"), systemImage: "doc.on.doc") {
                            guard !deck.code.isEmpty else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deck.code, forType: .string)
                        }
                        .disabled(deck.code.isEmpty)
                        .opacity(deck.code.isEmpty ? 0.4 : 1)
                    }
                    TextField(HearthChrome.L("标签，用逗号分开", "Tags, separated by commas"), text: Binding(
                        get: { store.deckMarks.tag(for: deck.id) },
                        set: { store.deckMarks.setTag(deck.id, $0) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    statsHeader(overall)

                    rateBreakdown(
                        HearthChrome.L("赛制", "Format"),
                        rows: store.history.grouped(deckID: deck.id) { $0.format ?? HearthChrome.L("未记录", "Unlisted") }
                    )
                    rateBreakdown(
                        HearthChrome.L("我的职业（全部记录）", "Your class (all games)"),
                        rows: store.history.grouped(deckID: nil) { entry in
                            store.deckLibrary.decks.first { $0.id == entry.deckID }?.className ?? HearthChrome.L("未知", "Unknown")
                        }
                    )

                    classBreakdown(deck)

                    mulliganStats(deck)

                    recentMatches(deck)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle()
                .fill(Color.line)
                .frame(width: 1)

            deckCardList(deck)
        }
    }

    private func metaPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.hearthText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func goldButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.onGold)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.gold, Color(red: 184 / 255, green: 132 / 255, blue: 62 / 255)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .shadow(color: Color.gold.opacity(0.28), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func statsHeader(_ stats: MatchHistoryStore.DeckStats) -> some View {
        HStack(spacing: 24) {
            winRateRing(stats)
            statBlock(HearthChrome.L("总场次", "Games"), "\(stats.games)")
            statBlock(HearthChrome.L("胜 / 负 / 平", "W / L / T"), "\(stats.wins) / \(stats.losses) / \(stats.ties)")
            Spacer()
        }
        .modifier(PanelSurface(pad: 18))
        .softAppear()
    }

    /// The win-rate ring is the deck page's visual anchor.
    private func winRateRing(_ stats: MatchHistoryStore.DeckStats) -> some View {
        let rate = stats.games > 0 ? stats.winRate : 0

        return ZStack {
            Circle()
                .stroke(Color.line, lineWidth: 7)
            Circle()
                .trim(from: 0, to: rate)
                .stroke(
                    LinearGradient(
                        colors: [Color.mint, Color.gold.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(HearthChrome.Motion.optional(.easeInOut(duration: 0.4)), value: rate)
                .shadow(color: Color.mint.opacity(0.35), radius: 4)
            VStack(spacing: 0) {
                Text(stats.games > 0 ? "\(Int(rate * 100))%" : "—")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.hearthText)
                    .contentTransition(.numericText())
                Text(HearthChrome.L("胜率", "Win rate"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.mist)
            }
        }
        .frame(width: 72, height: 72)
    }

    private func statBlock(_ label: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
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
                    sectionTitle(HearthChrome.L("起手留牌（样本 \(matches.count) 局）", "Mulligan (\(matches.count) games)"))
                    ForEach(rows.prefix(10), id: \.name) { row in
                        mulliganRowView(row, deck: deck)
                    }
                    Text(HearthChrome.L(
                        "样本越多越可靠；同一张卡两个数字差距大 = 留牌倾向有信号",
                        "More games, clearer signal. A big gap between the two rates means the keep matters."
                    ))
                        .font(.caption2)
                        .foregroundStyle(Color.mist.opacity(0.7))
                }
                .modifier(PanelSurface())
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
                .foregroundStyle(Color.hearthText)
                .lineLimit(1)
            Spacer()
            if row.kept > 0 {
                statPair(HearthChrome.L("留 \(row.kept)", "Kept \(row.kept)"), keptRate)
            }
            if row.discarded > 0 {
                statPair(HearthChrome.L("换 \(row.discarded)", "Tossed \(row.discarded)"), dropRate)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statPair(_ label: String, _ rate: Double) -> some View {
        Text("\(label) · \(Int(rate * 100))%")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(rate >= 0.5 ? Color.mint : Color.gold)
    }

    private func rateBreakdown(_ title: String, rows: [(String, MatchHistoryStore.DeckStats)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            if rows.isEmpty {
                Text(HearthChrome.L("暂无对局数据", "No games yet"))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(HearthChrome.phrase(row.0))
                            .font(.subheadline)
                            .foregroundStyle(Color.hearthText)
                        Spacer()
                        Text(HearthChrome.L(
                            "\(row.1.wins)胜 \(row.1.losses)负 \(row.1.ties)平",
                            "\(row.1.wins)W \(row.1.losses)L \(row.1.ties)T"
                        ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.mist)
                        Text(row.1.games > 0 ? "\(Int(row.1.winRate * 100))%" : "—")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(row.1.winRate >= 0.5 ? Color.mint : Color.gold)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .modifier(PanelSurface())
    }

    private func classBreakdown(_ deck: DeckLibraryStore.DeckSummary) -> some View {
        let classNames = orderedClasses(deck)

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(HearthChrome.L("面对各职业", "Versus class"))
            if classNames.isEmpty {
                Text(HearthChrome.L("暂无对局数据", "No games yet"))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(classNames, id: \.self) { className in
                    classRow(className: className, deckID: deck.id)
                }
            }
        }
        .modifier(PanelSurface())
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.gold)
                .frame(width: 3, height: 14)
            Text(text)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.hearthText)
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
            HStack(spacing: 8) {
                Circle()
                    .fill(Self.classColor(className))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                Text(HearthChrome.phrase(className))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.hearthText)
                Spacer()
                Text(HearthChrome.L("\(stats.wins)胜 \(stats.losses)负", "\(stats.wins)W \(stats.losses)L"))
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
        let matches = filteredHistory(deckID: deck.id)

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(HearthChrome.L("最近对局", "Recent games"))
            HStack(spacing: 8) {
                TextField(HearthChrome.L("搜索对手、卡组或备注", "Search class, deck, or note"), text: $historyQuery)
                    .textFieldStyle(.roundedBorder)
                Picker(HearthChrome.L("结果", "Result"), selection: $historyOutcome) {
                    Text(HearthChrome.L("全部", "All")).tag(0)
                    Text(HearthChrome.L("胜", "W")).tag(1)
                    Text(HearthChrome.L("负", "L")).tag(2)
                    Text(HearthChrome.L("平", "T")).tag(3)
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }
            if matches.isEmpty {
                Text(HearthChrome.L("还没有符合条件的对局", "No matching games"))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            } else {
                ForEach(Array(matches.prefix(40))) { entry in
                    matchRow(entry)
                }
            }
        }
        .modifier(PanelSurface())
    }

    private func filteredHistory(deckID: Int) -> [MatchHistoryEntry] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.history.entries
            .filter { entry in
                guard entry.deckID == deckID else { return false }
                switch historyOutcome {
                case 1 where entry.result != .win: return false
                case 2 where entry.result != .loss: return false
                case 3 where entry.result != .tie: return false
                default: break
                }
                guard !query.isEmpty else { return true }
                let note = store.history.note(for: entry.id)
                let haystack = [entry.opponentClass, entry.deckName, entry.format ?? "", note].joined(separator: " ")
                return haystack.localizedStandardContains(query)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func matchRow(_ entry: MatchHistoryEntry) -> some View {
        let expanded = expandedMatchID == entry.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                HearthChrome.Motion.run {
                    expandedMatchID = expanded ? nil : entry.id
                }
            } label: {
                HStack(spacing: 12) {
                    Text(entry.result == .win ? HearthChrome.L("胜", "W") : entry.result == .loss ? HearthChrome.L("负", "L") : HearthChrome.L("平", "T"))
                        .font(.caption.bold())
                        .foregroundStyle(Color.onGold)
                        .frame(width: 26, height: 26)
                        .background(
                            entry.result == .win ? Color.mint :
                                entry.result == .loss ? Color.gold : Color.mist,
                            in: Circle()
                        )
                        .shadow(
                            color: (entry.result == .win ? Color.mint : Color.gold).opacity(0.28),
                            radius: 4,
                            y: 1
                        )
                    Text(HearthChrome.L("对阵 \(localizedOpponentClass(entry.opponentClass))", "vs \(HearthChrome.phrase(localizedOpponentClass(entry.opponentClass)))"))
                        .font(.subheadline)
                        .foregroundStyle(Color.hearthText)
                    Text(entry.deckName)
                        .font(.caption2)
                        .foregroundStyle(Color.mist)
                        .lineLimit(1)
                    if let format = entry.format {
                        Text(HearthChrome.phrase(format))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.mist.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.mist.opacity(0.12), in: Capsule())
                    }
                    if entry.integrity != .complete {
                        Text(HearthChrome.L("部分记录", "Partial"))
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
                TextField(HearthChrome.L("备注", "Note"), text: Binding(
                    get: { store.history.note(for: entry.id) },
                    set: { store.history.setNote(entry.id, $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 6)
                matchDetail(entry)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .modifier(HoverHighlight(
            selected: expanded,
            radius: 12,
            selectedFill: Color.inkDeep.opacity(0.85),
            selectedStroke: Color.gold.opacity(0.28)
        ))
    }

    /// Inline post-game review: everything both sides showed this match.
    private func matchDetail(_ entry: MatchHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CardOrigin.allCases, id: \.self) { origin in
                let cards = (entry.opponentCards ?? [])
                    .filter { $0.origin == origin && !$0.isBoardOnly }
                    .sorted { $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost }
                if !cards.isEmpty {
                    detailGroup(HearthChrome.L("对手 · \(origin.title)", "Opponent · \(HearthChrome.phrase(origin.title))"), tint: origin == .original ? .mint : .mist) {
                        ForEach(cards) { card in
                            detailCardRow(card, trailing: HearthChrome.L("回合 \(card.playedTurn)", "Turn \(card.playedTurn)"))
                        }
                    }
                }
            }

            let played = entry.playerPlayedCards ?? []
            if !played.isEmpty {
                detailGroup(HearthChrome.L("己方 · 已打出", "You · played"), tint: .gold) {
                    ForEach(played) { card in
                        detailCardRow(card, trailing: HearthChrome.L("回合 \(card.playedTurn)", "Turn \(card.playedTurn)"))
                    }
                }
            }

            let remaining = (entry.playerRemainingCards ?? []).sorted {
                $0.cost == $1.cost ? $0.name < $1.name : $0.cost < $1.cost
            }
            if !remaining.isEmpty {
                detailGroup(HearthChrome.L("己方 · 终局牌库", "You · deck left"), tint: .gold) {
                    ForEach(remaining) { card in
                        detailCardRow(card, trailing: "×\(card.copies)")
                    }
                }
            }

            if (entry.opponentCards ?? []).isEmpty && (entry.playerPlayedCards ?? []).isEmpty {
                Text(HearthChrome.L("本局没有保存卡牌快照", "No card snapshot was saved for this game"))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
            }

            OpponentInferenceView(
                cards: entry.opponentCards ?? [],
                deckCount: nil,
                catalog: store.cardData.catalog
            )

            turnTimeline(entry)
            opponentDeckExport(entry)
        }
        .padding(.top, 6)
    }

    /// 逐回合时间线：每回合双方打出的牌。
    @ViewBuilder
    private func turnTimeline(_ entry: MatchHistoryEntry) -> some View {
        if let turns = entry.turns, !turns.isEmpty {
            detailGroup(HearthChrome.L("回合时间线", "Turn timeline"), tint: .gold) {
                ForEach(turns, id: \.turn) { turn in
                    HStack(alignment: .top, spacing: 10) {
                        Text("T\(turn.turn)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color.gold)
                            .frame(width: 26, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            if !turn.friendlyPlays.isEmpty {
                                turnPlayRow(HearthChrome.L("己", "You"), .mint, turn.friendlyPlays)
                            }
                            if !turn.opponentPlays.isEmpty {
                                turnPlayRow(HearthChrome.L("敌", "Opp"), .gold, turn.opponentPlays)
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
            .foregroundStyle(Color.hearthText.opacity(0.85))
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
                goldButton(HearthChrome.L("复制对手卡组代码", "Copy opponent code"), systemImage: "doc.on.doc") {
                    let code = DeckCode.encode(
                        heroDbfID: heroDbfID,
                        cards: entries,
                        format: deckFormatCode(entry.format)
                    )
                    guard !code.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.line, lineWidth: 1)
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
                Color.cardStrip.opacity(0.55)
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
            HStack(alignment: .firstTextBaseline) {
                Text(HearthChrome.L("牌表", "List"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.hearthText)
                Text("\(visible.count)/\(deck.cards.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.mist)
                Spacer()
                if filters.isActive {
                    Button(HearthChrome.L("重置筛选", "Reset")) {
                        HearthChrome.Motion.run {
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

            Rectangle()
                .fill(Color.line)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if deck.cards.isEmpty {
                        deckListEmpty(HearthChrome.L("卡牌数据未就绪", "Card data isn't ready"), systemImage: "square.dashed")
                    } else if visible.isEmpty {
                        deckListEmpty(HearthChrome.L("没有符合条件的卡", "No cards match"), systemImage: "line.3.horizontal.decrease.circle")
                    } else {
                        ForEach(visible, id: \.cardID) { card in
                            deckCardRow(cardID: card.cardID, count: card.count, hoveredCardID: $hoveredCardID)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .frame(width: 296)
        .background(Color.inkLift.opacity(0.28))
        .overlay(alignment: .trailing) {
            hoverCardPreview
        }
    }

    private func deckListEmpty(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.gold.opacity(0.85))
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.mist)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 12)
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
                Text(HearthChrome.L("更多筛选（机制 / 归属 / 属性）", "More filters (mechanic / class / tribe)"))
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
                        HearthChrome.Motion.run {
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
        @State private var hovering = false
        @Environment(\.hearthContext) private var hearthContext

        var body: some View {
            let _ = HearthChrome.install(hearthContext)
            return Button(action: action) {
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(HearthChrome.phrase(label))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.hearthText.opacity(isOn || hovering ? 1 : 0.82))
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(isOn ? tint : Color.mist)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isOn ? tint.opacity(0.32) : (hovering ? Color.hoverWash : Color.inkDeep.opacity(0.55)))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? tint.opacity(0.9) : (hovering ? tint.opacity(0.5) : Color.line),
                        lineWidth: 1
                    )
                )
                .scaleEffect(isOn ? HearthChrome.Motion.chipScaleOn : (hovering ? HearthChrome.Motion.chipScaleHover : 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
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
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.gold.opacity(0.85), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
                    .allowsHitTesting(false)
                if let comboNote {
                    Text(comboNote)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.onGold)
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
        guard hoveredCardID != nil else { return nil }
        return HearthChrome.L("金色边框 = 与此卡有配合", "Gold border = combos with this card")
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
                Color.cardStrip.opacity(0.55)
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
        @Environment(\.hearthContext) private var hearthContext

        var body: some View {
            let peak = max(curve.max() ?? 1, 1)
            let _ = HearthChrome.install(hearthContext)

            return VStack(alignment: .leading, spacing: 6) {
                Text(HearthChrome.L("费用曲线", "Mana curve"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.mist)
                curveBars(peak: peak)
            }
            .padding(10)
            .background(Color.inkDeep.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.line, lineWidth: 1)
            )
        }

        private func curveBars(peak: Int) -> some View {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(curve.enumerated()), id: \.offset) { index, count in
                    let isSelected = selection.contains(index)
                    Button {
                        HearthChrome.Motion.run {
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
                                .animation(HearthChrome.Motion.optional(.spring(response: 0.35, dampingFraction: 0.82)), value: count)
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

/// Selected and hovered row chrome shared by the sidebar and match list.
private struct HoverHighlight: ViewModifier {
    var selected: Bool
    var radius: CGFloat = 10
    var selectedFill: Color = .panel
    var selectedStroke: Color = Color.gold.opacity(0.72)
    @State private var hovering = false
    @Environment(\.hearthContext) private var hearthContext

    func body(content: Content) -> some View {
        let _ = HearthChrome.install(hearthContext)
        return content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? selectedFill : (hovering ? Color.hoverWash : Color.clear))
                    .animation(.easeOut(duration: 0.16), value: hovering)
                    .animation(.easeOut(duration: 0.16), value: selected)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        selected ? selectedStroke : (hovering ? Color.line : Color.clear),
                        lineWidth: 1
                    )
                    .animation(.easeOut(duration: 0.16), value: hovering)
                    .animation(.easeOut(duration: 0.16), value: selected)
            )
            .onHover { hovering = $0 }
    }
}

/// Inset panel used for win rate, matchup and history sections.
private struct PanelSurface: ViewModifier {
    var pad: CGFloat = 16
    @Environment(\.hearthContext) private var hearthContext

    func body(content: Content) -> some View {
        let _ = HearthChrome.install(hearthContext)
        return content
            .padding(pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.inkLift.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.gold.opacity(0.38),
                                Color.line,
                                Color.hearthText.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}
