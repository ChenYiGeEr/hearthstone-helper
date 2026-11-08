import AppKit
import SwiftUI
import HearthstoneCore

/// 游戏图鉴式全卡浏览：按格式（标准/狂野）、职业、类型、稀有度、机制、
/// 费用筛选，分页网格展示高清官方渲染卡图。
///
/// 性能要点：过滤结果只在筛选参数变化时重算并缓存（悬浮不再触发
/// 8000+ 张的全量过滤）；网格是独立子视图，hover 状态变化只重算它自己；
/// 图片走 512px HD 通道、后台解码、相邻页预取。
struct CollectionBrowser: View {
    let store: MatchStore
    /// true = 标准, false = 狂野（由主窗口格式开关控制）。
    let isStandard: Bool

    @State private var selectedClass: String? = nil
    @State private var types: Set<String> = []
    @State private var rarities: Set<String> = []
    @State private var costs: Set<Int> = []
    @State private var mechanics: Set<String> = []
    @State private var page = 0

    @State private var results: [String] = []
    @State private var chipCounts: [String: [(String, Int)]] = [:]
    @State private var classCounts: [(String, Int)] = []

    private let pageSize = 48

    private var catalog: CardCatalog? { store.cardData.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            filterRows
            CollectionGrid(
                cardIDs: pageCards,
                store: store
            )
            pager
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 图鉴是启动首页,10MB 元数据可能仍在后台解析:状态变化时若
        // 还没算过结果就补算,避免首屏空白要靠切格式才出数据。
        .task(id: store.cardData.state) {
            if store.cardData.catalog != nil, results.isEmpty {
                recompute()
            }
        }
        .onChange(of: isStandard) { _, _ in recompute() }
    }

    private var pageCount: Int {
        max((results.count + pageSize - 1) / pageSize, 1)
    }

    private var pageCards: [String] {
        Array(results.dropFirst(page * pageSize).prefix(pageSize))
    }

    // MARK: - Recompute (only on filter changes)

    private func recompute() {
        guard let catalog else { return }
        let owned = store.live.collection?.owned
        let pool = catalog.collectibleCardIDs.filter { cardID in
            let formatOK = isStandard ? catalog.isStandard(cardID) : !catalog.isStandard(cardID)
            let ownedOK = !collectionMode || (owned?[cardID] ?? 0) > 0
            return formatOK && ownedOK
        }
        let classPool = pool.filter { cardID in
            selectedClass == nil || catalog.classLabel(for: cardID) == selectedClass
        }

        func matchesExcept(_ cardID: String, dimension: String) -> Bool {
            if dimension != "type", !types.isEmpty, !types.contains(catalog.typeLabel(for: cardID)) { return false }
            if dimension != "rarity", !rarities.isEmpty, !rarities.contains(catalog.rarityLabel(for: cardID)) { return false }
            if dimension != "cost", !costs.isEmpty, !costs.contains(catalog.costBucket(for: cardID)) { return false }
            if dimension != "mechanic", !mechanics.isEmpty, mechanics.isDisjoint(with: catalog.mechanicLabels(for: cardID)) { return false }
            return true
        }

        // final result list
        results = classPool.filter { cardID in matchesExcept(cardID, dimension: "") }

        // chip counts with own-dimension exemption
        func dimensionCounts(
            dimension: String,
            _ label: (String) -> String
        ) -> [String: Int] {
            var tally: [String: Int] = [:]
            for cardID in classPool where matchesExcept(cardID, dimension: dimension) {
                tally[label(cardID), default: 0] += 1
            }
            return tally
        }

        let typeCounts = dimensionCounts(dimension: "type") { catalog.typeLabel(for: $0) }
        let rarityCounts = dimensionCounts(dimension: "rarity") { catalog.rarityLabel(for: $0) }
        let costCounts = dimensionCounts(dimension: "cost") {
            let bucket = catalog.costBucket(for: $0)
            return bucket == 7 ? "7+" : "\(bucket)"
        }
        var mechanicTally: [String: Int] = [:]
        for cardID in classPool where matchesExcept(cardID, dimension: "mechanic") {
            for label in catalog.mechanicLabels(for: cardID) {
                mechanicTally[label, default: 0] += 1
            }
        }

        chipCounts = [
            "type": ["随从", "法术", "武器", "任务", "英雄", "地标"].compactMap { name in
                typeCounts[name].map { (name, $0) }
            },
            "rarity": ["传说", "史诗", "稀有", "普通"].compactMap { name in
                rarityCounts[name].map { (name, $0) }
            },
            "cost": ["0", "1", "2", "3", "4", "5", "6", "7+"].compactMap { name in
                costCounts[name].map { (name, $0) }
            },
            "mechanic": Array(CardCatalog.mechanicDisplayNames.values)
                .compactMap { name in mechanicTally[name].map { (name, $0) } }
                .sorted { $0.1 > $1.1 },
        ]

        var classTotals: [String: Int] = [:]
        for cardID in pool {
            classTotals[catalog.classLabel(for: cardID), default: 0] += 1
        }
        let order = ["中立", "法师", "猎人", "战士", "牧师", "术士", "潜行者", "萨满祭司", "圣骑士", "德鲁伊", "死亡骑士", "恶魔猎手"]
        classCounts = order.compactMap { name in classTotals[name].map { (name, $0) } }

        if page >= pageCount { page = max(pageCount - 1, 0) }
        prefetchNeighbors()
    }

    private func prefetchNeighbors() {
        let next = Array(results.dropFirst((page + 1) * pageSize).prefix(pageSize))
        store.cardImages.prefetchHD(next)
    }

    // MARK: - Header & filters

    @State private var collectionMode = false

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isStandard ? "卡牌图鉴 · 标准" : "卡牌图鉴 · 狂野")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text("共 \(results.count) 张")
                        .font(.caption)
                        .foregroundStyle(Color.mist)
                    if collectionMode, let coll = store.live.collection {
                        Text("粉尘 \(coll.dust) · 金币 \(coll.gold)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.gold)
                    }
                }
            }
            Spacer()
            Picker("", selection: $collectionMode) {
                Text("全部").tag(false)
                Text("我的收藏").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: collectionMode) { _, _ in
                if collectionMode { store.live.fetchCollectionIfNeeded() }
                recompute()
            }
            if isActiveFilter {
                Button("重置筛选") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedClass = nil
                        types = []
                        rarities = []
                        costs = []
                        mechanics = []
                        page = 0
                        recompute()
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.gold)
                .buttonStyle(.plain)
            }
        }
    }

    private var isActiveFilter: Bool {
        selectedClass != nil || !types.isEmpty || !rarities.isEmpty
            || !costs.isEmpty || !mechanics.isEmpty
    }

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChipTinted(label: "全部职业", count: results.isEmpty ? 0 : classCounts.reduce(0) { $0 + $1.1 }, tint: .gold, isOn: selectedClass == nil) {
                        selectClass(nil)
                    }
                    ForEach(classCounts, id: \.0) { entry in
                        FilterChipTinted(label: entry.0, count: entry.1, tint: .mint, isOn: selectedClass == entry.0) {
                            selectClass(entry.0)
                        }
                    }
                }
            }
            chipRow(values: chipCounts["type"] ?? [], selection: $types, key: "type", tint: .mint)
            chipRow(values: chipCounts["rarity"] ?? [], selection: $rarities, key: "rarity", tint: .gold)
            chipRow(values: chipCounts["cost"] ?? [], selection: costsLabels, key: nil, tint: .mint)
            chipRow(values: chipCounts["mechanic"] ?? [], selection: $mechanics, key: "mechanic", tint: .mint)
        }
    }

    /// 费用筛选以显示名存储（"7+" ↔ bucket 7）。
    private var costsLabels: Binding<Set<String>> {
        Binding(
            get: { Set(costs.map { $0 == 7 ? "7+" : "\($0)" }) },
            set: { labels in
                costs = Set(labels.compactMap { $0 == "7+" ? 7 : Int($0) })
                page = 0
                recompute()
            }
        )
    }

    private func selectClass(_ value: String?) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedClass = value
            page = 0
            recompute()
        }
    }

    /// key nil 表示 selection 已在 setter 里触发 recompute（桥接 Binding）。
    private func chipRow(
        values: [(String, Int)],
        selection: Binding<Set<String>>,
        key: String?,
        tint: Color
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.0) { value in
                    FilterChipTinted(
                        label: value.0,
                        count: value.1,
                        tint: tint,
                        isOn: selection.wrappedValue.contains(value.0)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if selection.wrappedValue.contains(value.0) {
                                selection.wrappedValue.remove(value.0)
                            } else {
                                selection.wrappedValue.insert(value.0)
                            }
                            page = 0
                            if key != nil {
                                recompute()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pager

    private var pager: some View {
        HStack(spacing: 14) {
            pagerButton("chevron.left") {
                if page > 0 {
                    page -= 1
                    prefetchNeighbors()
                }
            }
            .disabled(page == 0)

            Text("\(page + 1) / \(pageCount)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.inkLift, in: Capsule())

            pagerButton("chevron.right") {
                if page < pageCount - 1 {
                    page += 1
                    prefetchNeighbors()
                }
            }
            .disabled(page >= pageCount - 1)
        }
    }

    private func pagerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.gold)
                .frame(width: 26, height: 26)
                .background(Color.inkLift, in: Circle())
                .overlay(Circle().strokeBorder(Color.gold.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 网格 + 悬浮预览独立成子视图：hover 只触发这里重算，不牵动整个浏览器。
/// 大图出现在鼠标的**对侧**——悬浮右侧卡牌时预览在左，避免挡住鼠标。
private struct CollectionGrid: View {
    let cardIDs: [String]
    let store: MatchStore
    @State private var hoveredCardID: String?
    @State private var hoverIsOnRightSide = false
    @State private var gridMidX: CGFloat = 0
    @State private var loadingPulse = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 122), spacing: 12)],
                spacing: 12
            ) {
                ForEach(cardIDs, id: \.self) { cardID in
                    cell(cardID)
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    gridMidX = geo.frame(in: .global).midX
                }
            }
        )
        .overlay(alignment: hoverIsOnRightSide ? .leading : .trailing) {
            if let cardID = hoveredCardID,
               let image = store.cardImages.hdImage(for: cardID) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 260, height: 260 * 776.0 / 512.0)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
                    .padding(hoverIsOnRightSide ? .leading : .trailing, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .animation(.spring(response: 0.3, dampingFraction: 1.0), value: hoveredCardID)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                loadingPulse = true
            }
        }
    }

    private func cell(_ cardID: String) -> some View {
        let isHovered = hoveredCardID == cardID

        return Group {
            if let image = store.cardImages.hdImage(for: cardID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(512.0 / 776.0, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.inkLift)
                    .aspectRatio(512.0 / 776.0, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text(store.cardData.catalog?.displayName(for: cardID) ?? cardID)
                                .font(.caption2)
                                .foregroundStyle(Color.mist)
                                .multilineTextAlignment(.center)
                                .padding(6)
                        }
                    )
                    .opacity(loadingPulse ? 0.55 : 1.0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gold, lineWidth: isHovered ? 2 : 0)
                .shadow(color: .black.opacity(0.4), radius: 4)
        )
        .scaleEffect(isHovered ? 1.04 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.45 : 0.2), radius: isHovered ? 8 : 3, y: isHovered ? 4 : 2)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: isHovered)
        .onAppear {
            store.cardImages.prefetchHD([cardID])
            if store.cardImages.hdImage(for: cardID) == nil {
                loadingPulse = true
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredCardID = cardID
                hoverIsOnRightSide = gridMidX > 0 && NSEvent.mouseLocation.x > gridMidX
            } else if hoveredCardID == cardID {
                hoveredCardID = nil
            }
        }
    }
}

/// 独立命名的筛选胶囊（避免与卡组侧的 FilterChip 重名冲突）。
struct FilterChipTinted: View {
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
            .background(Capsule().fill(isOn ? tint.opacity(0.28) : Color(red: 14 / 255, green: 22 / 255, blue: 29 / 255).opacity(0.55)))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.8) : Color.mist.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    static let gold = Color(red: 214 / 255, green: 168 / 255, blue: 93 / 255)
    static let mint = Color(red: 105 / 255, green: 200 / 255, blue: 176 / 255)
    static let mist = Color(red: 142 / 255, green: 162 / 255, blue: 176 / 255)
    static let inkLift = Color(red: 23 / 255, green: 38 / 255, blue: 48 / 255)
}
