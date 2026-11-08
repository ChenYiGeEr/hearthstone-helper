import AppKit
import Foundation
import Observation
import HearthstoneCore

@MainActor
@Observable
final class MatchStore {
    var status: LogPipelineStatus = .notRunning
    var selectedCard: TrackedCard?
    var isPlayerPanelVisible = true
    var isOpponentPanelVisible = true

    // Overlay interaction state. Panels are interactive by default (draggable
    // title, scrolling, hover previews); pass-through is an opt-in escape hatch.
    var isOverlayPassthrough = false
    var isOpponentOverlayVisible = true
    var isPlayerOverlayVisible = true

    let monitor = PowerLogMonitor()
    let cardData = CardDataStore()
    let cardImages = CardImageStore()
    let mirror = MirrorBridge.shared
    let live = MirrorLiveStore()
    let memory = MirrorMemoryStore()
    let history = MatchHistoryStore()
    let deckLibrary = DeckLibraryStore()
    let lifecycle = LifecycleAutomation()

    private var lastFinishedRecordID: UUID?
    private var lastStatusKind: LogPipelineStatus?

    private static let opacityKey = "overlay-opacity-level"
    private static let themeKey = "appearance-theme"
    private static let languageKey = "ui-language"
    private static let motionKey = "motion-level"
    private static let overlayThemeKey = "overlay-theme"
    private static let overlayLayoutKey = "overlay-layout"

    var overlayOpacityLevel: Int {
        didSet {
            guard oldValue != overlayOpacityLevel else { return }
            UserDefaults.standard.set(overlayOpacityLevel, forKey: Self.opacityKey)
        }
    }

    /// 0 system, 1 light, 2 dark. Default stays dark, matching the original UI.
    var appearanceChoice: Int {
        didSet {
            guard oldValue != appearanceChoice else { return }
            UserDefaults.standard.set(appearanceChoice, forKey: Self.themeKey)
            HearthChrome.applyAppAppearance(AppearanceChoice(rawValue: appearanceChoice) ?? .dark)
        }
    }

    /// 0 中文, 1 English.
    var interfaceLanguage: Int {
        didSet {
            guard oldValue != interfaceLanguage else { return }
            UserDefaults.standard.set(interfaceLanguage, forKey: Self.languageKey)
            HearthChrome.language = InterfaceLanguage(rawValue: interfaceLanguage) ?? .chinese
        }
    }

    var chromeRevision: Int {
        appearanceChoice &* 10
            &+ interfaceLanguage
            &+ motionLevel &* 100
            &+ overlayTheme &* 1_000
            &+ overlayLayout &* 10_000
    }

    /// 0 off, 1 light, 2 flashy.
    var motionLevel: Int {
        didSet {
            guard oldValue != motionLevel else { return }
            UserDefaults.standard.set(motionLevel, forKey: Self.motionKey)
            HearthChrome.motion = MotionLevel(rawValue: motionLevel) ?? .light
        }
    }

    /// 0 follow app, 1 light, 2 dark.
    var overlayTheme: Int {
        didSet {
            guard oldValue != overlayTheme else { return }
            UserDefaults.standard.set(overlayTheme, forKey: Self.overlayThemeKey)
        }
    }

    var overlayLayout: Int {
        didSet {
            guard oldValue != overlayLayout else { return }
            UserDefaults.standard.set(overlayLayout, forKey: Self.overlayLayoutKey)
            syncLayoutVisibility()
            OverlayWindowManager.shared.applyLayoutPreset(overlayLayout)
        }
    }

    let deckMarks = DeckMarks()

    /// Background tint for the overlay panels, by user-selected transparency level.
    var overlayBackgroundOpacity: Double {
        switch overlayOpacityLevel {
        case 0: 0.15
        case 2: 0.70
        default: 0.42
        }
    }

    var match: MatchRecord {
        let raw = status.match ?? .preview
        return cardData.catalog?.apply(to: raw) ?? raw
    }

    var isShowingPreview: Bool {
        status.match == nil
    }

    /// 浮窗手牌列表：内存 ZoneHand 里的 cardID 是准的（T5 日志在换牌重发
    /// 阶段会让手牌滞后、缺张），日志只用来提供费用/来源等元数据；内存读
    /// 不到时整体回退到日志列表。
    var playerHandCardsResolved: [TrackedCard] {
        let logCards = match.playerHandCards
        guard let ids = memory.friendlyHandCardIDs, !ids.isEmpty else { return logCards }

        // 元数据优先级（后者覆盖前者）：已打出 < 牌库 < 洗入 < 日志手牌
        var metadata: [String: TrackedCard] = [:]
        for card in match.playerPlayedCards { metadata[card.cardID ?? card.name] = card }
        for card in match.playerRemainingCards { metadata[card.cardID ?? card.name] = card }
        for card in match.playerShuffledCards { metadata[card.cardID ?? card.name] = card }
        for card in logCards { metadata[card.cardID ?? card.name] = card }

        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in ids where !id.isEmpty {
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        guard !order.isEmpty else { return logCards }

        return order.map { id in
            guard let meta = metadata[id] else {
                // 日志还没见过这张牌（重发滞后）：直接用内存 cardID 建行，
                // 费用/名称由卡牌目录在显示时补全
                return TrackedCard(
                    name: id,
                    cardID: id,
                    cost: 0,
                    copies: counts[id] ?? 1,
                    origin: .original,
                    playedTurn: 0,
                    currentZone: "HAND"
                )
            }
            return TrackedCard(
                name: meta.name,
                cardID: meta.cardID,
                cost: meta.cost,
                copies: counts[id] ?? 1,
                origin: meta.origin,
                playedTurn: 0,
                sourceTrail: meta.sourceTrail,
                isBoardOnly: meta.isBoardOnly,
                currentZone: "HAND"
            )
        }
    }

    init() {
        let themeRaw = UserDefaults.standard.object(forKey: Self.themeKey) as? Int ?? AppearanceChoice.dark.rawValue
        let languageRaw = UserDefaults.standard.object(forKey: Self.languageKey) as? Int ?? InterfaceLanguage.chinese.rawValue
        appearanceChoice = themeRaw
        interfaceLanguage = languageRaw
        motionLevel = UserDefaults.standard.object(forKey: Self.motionKey) as? Int ?? MotionLevel.light.rawValue
        overlayTheme = UserDefaults.standard.object(forKey: Self.overlayThemeKey) as? Int ?? OverlayThemeChoice.followApp.rawValue
        overlayLayout = UserDefaults.standard.object(forKey: Self.overlayLayoutKey) as? Int ?? OverlayLayoutPreset.standard.rawValue
        overlayOpacityLevel = UserDefaults.standard.object(forKey: Self.opacityKey) as? Int ?? 1
        let choice = AppearanceChoice(rawValue: themeRaw) ?? .dark
        HearthChrome.pendingChoice = choice
        HearthChrome.language = InterfaceLanguage(rawValue: languageRaw) ?? .chinese
        HearthChrome.motion = MotionLevel(rawValue: motionLevel) ?? .light
        HearthChrome.isLight = choice == .light
        syncLayoutVisibility()

        monitor.deckListResolver = { [weak self] code in
            guard let self else { return [] }
            // the mirror's selected deck is authoritative while a game runs
            if let id = self.live.selectedDeckID,
               let deck = self.live.ownDecks.first(where: { $0.id == id }) {
                return deck.cards
            }
            return Self.resolveDeckList(code: code, catalog: self.cardData.catalog)
        }

        monitor.onStatus = { [weak self] status in
            guard let self else { return }
            self.status = status
            if let record = status.match {
                self.prefetchCardImages(for: record)
            }
            // log-based fallback refresh uses mirror decks when available
            self.deckLibrary.refresh(
                catalog: self.cardData.catalog,
                mirrorDecks: self.live.ownDecks
            )
            // a finished match becomes one history entry, once; store the
            // localized record so the detail view shows real card names.
            // Wait for the card catalog: otherwise raw cardIDs/classIDs get
            // frozen into history (the 30s self-heal re-publishes later).
            if case .finished = status, cardData.catalog != nil, self.match.id != self.lastFinishedRecordID {
                self.lastFinishedRecordID = self.match.id
                let formatName: String? = live.formatType.map {
                    $0 == 2 ? "标准" : $0 == 1 ? "狂野" : $0 == 3 ? "经典" : $0 == 4 ? "幻变" : "其他"
                }
                let rawHero = status.match?.opponentClass
                let heroCardID = rawHero.flatMap { id in
                    self.cardData.catalog?.classDisplayName(forHeroCardID: id) != nil ? id : nil
                }
                self.history.appendIfNeeded(
                    from: self.match,
                    format: formatName,
                    opponentHeroCardID: heroCardID
                )
                self.deckLibrary.refresh(catalog: self.cardData.catalog)
            }
            if Self.statusKind(status) != Self.statusKind(self.lastStatusKind) {
                self.lastStatusKind = status
                self.deckLibrary.refresh(catalog: self.cardData.catalog)
            }
        }
        monitor.start()
        live.start()
        memory.start()
        // mirror attach runs on a slow timer: game launch/exit and the first
        // task-port approval are asynchronous
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mirror.attachIfNeeded()
            }
        }
        monitor.start()
        Task {
            await cardData.bootstrap()
            if let catalog = cardData.catalog {
                history.relocalize(catalog: catalog)
            }
            deckLibrary.refresh(catalog: cardData.catalog, mirrorDecks: live.ownDecks)
        }

        // Decks.log updates when the client logs in or decks are edited — events
        // this app cannot observe directly — so poll the library on a slow timer.
        libraryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cardData.catalog != nil else { return }
                self.deckLibrary.refresh(catalog: self.cardData.catalog, mirrorDecks: self.live.ownDecks)
            }
        }
    }

    private var libraryRefreshTimer: Timer?

    /// deck code → (cardID × count) through the catalog's dbfId reverse index.
    private static func resolveDeckList(
        code: String,
        catalog: CardCatalog?
    ) -> [(cardID: String, count: Int)] {
        guard let catalog, let decoded = DeckCode.decode(code) else { return [] }
        return decoded.cards.compactMap { ref in
            guard let cardID = catalog.cardID(forDbfID: ref.dbfID) else { return nil }
            return (cardID, ref.count)
        }
    }

    /// Refreshing the deck library re-reads every Decks.log, so it must only
    /// happen on lifecycle transitions, not on every publish.
    private static func statusKind(_ status: LogPipelineStatus?) -> Int {
        switch status {
        case .missingLogConfig: return 0
        case .notRunning: return 1
        case .loggedIn: return 2
        case .live: return 3
        case .finished: return 4
        case nil: return -1
        }
    }

    private func prefetchCardImages(for record: MatchRecord) {
        var ids = record.opponentCards.map(\.cardID)
        ids += record.playerRemainingCards.map(\.cardID)
        ids += record.playerShuffledCards.map(\.cardID)
        ids += record.playerPlayedCards.map(\.cardID)
        ids += record.candidate.confirmedOriginalCards.map(\.cardID)
        cardImages.prefetch(ids.compactMap { $0 }.filter { !$0.isEmpty })
    }

    func togglePlayerPanel() {
        isPlayerPanelVisible.toggle()
    }

    func toggleOpponentPanel() {
        isOpponentPanelVisible.toggle()
    }

    func toggleOverlays() {
        let show = !(isOpponentOverlayVisible || isPlayerOverlayVisible)
        isOpponentOverlayVisible = show
        isPlayerOverlayVisible = show
    }

    func toggleLanguage() {
        interfaceLanguage = interfaceLanguage == InterfaceLanguage.english.rawValue
            ? InterfaceLanguage.chinese.rawValue
            : InterfaceLanguage.english.rawValue
    }

    func copyMatchSnapshot() {
        let record = match
        let friendly = record.friendlyStats
        let opponent = record.opponentStats
        let lines = [
            HearthChrome.L("对手", "Opponent") + ": " + HearthChrome.phrase(record.opponentClass),
            HearthChrome.L("卡组", "Deck") + ": " + record.playerDeckName,
            HearthChrome.L(
                "己方 手\(friendly?.handCount ?? 0) 库\(friendly?.deckCount ?? 0) 血\(friendly?.currentHealth ?? 0)",
                "You hand \(friendly?.handCount ?? 0) deck \(friendly?.deckCount ?? 0) hp \(friendly?.currentHealth ?? 0)"
            ),
            HearthChrome.L(
                "对手 手\(opponent?.handCount ?? 0) 库\(opponent?.deckCount ?? 0) 血\(opponent?.currentHealth ?? 0)",
                "Opponent hand \(opponent?.handCount ?? 0) deck \(opponent?.deckCount ?? 0) hp \(opponent?.currentHealth ?? 0)"
            ),
            HearthChrome.L("己方手牌", "Your hand") + ": " + record.playerHandCards.map(\.name).joined(separator: ", "),
            HearthChrome.L("对手已见", "Opponent seen") + ": " + record.opponentCards.map(\.name).joined(separator: ", ")
        ]
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func interfaceContext(systemIsLight: Bool, overlay: Bool) -> HearthContext {
        let app = AppearanceChoice(rawValue: appearanceChoice) ?? .dark
        let choice: AppearanceChoice
        if overlay {
            switch OverlayThemeChoice(rawValue: overlayTheme) ?? .followApp {
            case .followApp: choice = app
            case .light: choice = .light
            case .dark: choice = .dark
            }
        } else {
            choice = app
        }
        return HearthChrome.context(
            choice: choice,
            systemIsLight: systemIsLight,
            language: InterfaceLanguage(rawValue: interfaceLanguage) ?? .chinese,
            motion: MotionLevel(rawValue: motionLevel) ?? .light
        )
    }

    func exportDeckList() -> String {
        var lines: [String] = []
        for deck in deckLibrary.decks where !deck.code.isEmpty {
            lines.append("\(deck.name)\t\(deck.code)")
        }
        for deck in deckMarks.imported {
            lines.append("\(deck.name)\t\(deck.code)")
        }
        return lines.joined(separator: "\n")
    }

    func copyExportedDecks() {
        let text = exportDeckList()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func syncLayoutVisibility() {
        switch OverlayLayoutPreset(rawValue: overlayLayout) ?? .standard {
        case .deckOnly:
            isPlayerOverlayVisible = true
            isOpponentOverlayVisible = false
        case .opponentOnly:
            isPlayerOverlayVisible = false
            isOpponentOverlayVisible = true
        case .standard, .swapped, .narrow, .wide:
            isPlayerOverlayVisible = true
            isOpponentOverlayVisible = true
        }
    }
}
