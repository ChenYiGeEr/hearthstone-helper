import SwiftUI
import HearthstoneCore

struct ImportedDeck: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var code: String
}

/// Local favorites, tags, and display-only imported deck codes.
/// These never enter match resolution or win-rate totals.
@MainActor
@Observable
final class DeckMarks {
    private(set) var favorites: Set<Int> = []
    private(set) var tags: [Int: String] = [:]
    private(set) var imported: [ImportedDeck] = []

    private static let favoritesKey = "deck-favorites"
    private static let tagsKey = "deck-tags"
    private static let importedKey = "imported-decks"

    init() {
        if let raw = UserDefaults.standard.array(forKey: Self.favoritesKey) as? [Int] {
            favorites = Set(raw)
        }
        if let data = UserDefaults.standard.data(forKey: Self.tagsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            tags = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        if let data = UserDefaults.standard.data(forKey: Self.importedKey),
           let decoded = try? JSONDecoder().decode([ImportedDeck].self, from: data) {
            imported = decoded
        }
    }

    func isFavorite(_ id: Int) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: Int) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
    }

    func tag(for id: Int) -> String { tags[id] ?? "" }

    func setTag(_ id: Int, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { tags.removeValue(forKey: id) } else { tags[id] = trimmed }
        let raw = Dictionary(uniqueKeysWithValues: tags.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.tagsKey)
        }
    }

    @discardableResult
    func importCode(_ raw: String, catalog: CardCatalog?) -> Bool {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, DeckCode.decode(code) != nil else { return false }
        let decoded = DeckCode.decode(code)
        let heroID = decoded.flatMap { catalog?.cardID(forDbfID: $0.heroDbfID) }
        let className = heroID.flatMap { catalog?.classDisplayName(forHeroCardID: $0) } ?? HearthChrome.L("导入", "Import")
        imported.append(ImportedDeck(id: UUID(), name: className, code: code))
        saveImported()
        return true
    }

    func removeImported(_ id: UUID) {
        imported.removeAll { $0.id == id }
        saveImported()
    }

    func resolvedCards(_ deck: ImportedDeck, catalog: CardCatalog?) -> [(cardID: String, count: Int)] {
        guard let catalog, let decoded = DeckCode.decode(deck.code) else { return [] }
        return decoded.cards.compactMap { ref in
            catalog.cardID(forDbfID: ref.dbfID).map { ($0, ref.count) }
        }
    }

    private func saveImported() {
        if let data = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(data, forKey: Self.importedKey)
        }
    }
}

struct HelperSettingsPane: View {
    let store: MatchStore
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let _ = HearthChrome.install(store.interfaceContext(systemIsLight: systemScheme == .light, overlay: false))
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(HearthChrome.L("外观与动效", "Appearance and motion")) {
                    Picker(HearthChrome.L("外观", "Appearance"), selection: choice) {
                        Text(HearthChrome.L("跟随系统", "System")).tag(AppearanceChoice.system.rawValue)
                        Text(HearthChrome.L("浅色", "Light")).tag(AppearanceChoice.light.rawValue)
                        Text(HearthChrome.L("深色", "Dark")).tag(AppearanceChoice.dark.rawValue)
                    }
                    Picker(HearthChrome.L("动效", "Motion"), selection: motion) {
                        Text(HearthChrome.L("关", "Off")).tag(MotionLevel.off.rawValue)
                        Text(HearthChrome.L("轻", "Light")).tag(MotionLevel.light.rawValue)
                        Text(HearthChrome.L("炫", "Flashy")).tag(MotionLevel.flashy.rawValue)
                    }
                    Picker(HearthChrome.L("语言", "Language"), selection: language) {
                        Text("中文").tag(InterfaceLanguage.chinese.rawValue)
                        Text("English").tag(InterfaceLanguage.english.rawValue)
                    }
                }

                section(HearthChrome.L("浮窗", "Overlays")) {
                    Picker(HearthChrome.L("浮窗主题", "Overlay theme"), selection: overlayTheme) {
                        Text(HearthChrome.L("跟随应用", "Follow app")).tag(OverlayThemeChoice.followApp.rawValue)
                        Text(HearthChrome.L("浅色", "Light")).tag(OverlayThemeChoice.light.rawValue)
                        Text(HearthChrome.L("深色", "Dark")).tag(OverlayThemeChoice.dark.rawValue)
                    }
                    Picker(HearthChrome.L("浮窗布局", "Overlay layout"), selection: layout) {
                        Text(HearthChrome.L("左对手 · 右牌库", "Opponent left")).tag(OverlayLayoutPreset.standard.rawValue)
                        Text(HearthChrome.L("左右对调", "Swapped")).tag(OverlayLayoutPreset.swapped.rawValue)
                        Text(HearthChrome.L("窄", "Narrow")).tag(OverlayLayoutPreset.narrow.rawValue)
                        Text(HearthChrome.L("宽", "Wide")).tag(OverlayLayoutPreset.wide.rawValue)
                        Text(HearthChrome.L("只看牌库", "Deck only")).tag(OverlayLayoutPreset.deckOnly.rawValue)
                        Text(HearthChrome.L("只看对手", "Opponent only")).tag(OverlayLayoutPreset.opponentOnly.rawValue)
                    }
                    Picker(HearthChrome.L("浮窗透明度", "Overlay opacity"), selection: opacity) {
                        Text(HearthChrome.L("低", "Low")).tag(0)
                        Text(HearthChrome.L("中", "Medium")).tag(1)
                        Text(HearthChrome.L("高", "High")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    Toggle(HearthChrome.L("浮窗鼠标穿透（不挡游戏）", "Click through overlays"), isOn: passthrough)
                }

                section(HearthChrome.L("启动与退出", "Launch and quit")) {
                    Text(HearthChrome.L(
                        "这两项只影响助手自己，不会操作炉石。",
                        "These only affect the helper. They do not control Hearthstone."
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
                    Toggle(HearthChrome.L("登录 macOS 时自动启动助手", "Launch the helper when you log in to macOS"), isOn: Binding(
                        get: { store.lifecycle.launchesAtLogin },
                        set: { store.lifecycle.setLaunchesAtLogin($0) }
                    ))
                    Text(HearthChrome.L(
                        "打开后，这个 macOS 用户登录时会拉起助手。",
                        "When on, the helper starts for this macOS user at login."
                    ))
                    .font(.caption2)
                    .foregroundStyle(Color.mist)
                    Toggle(HearthChrome.L("炉石退出时自动退出助手", "Quit the helper when Hearthstone quits"), isOn: Binding(
                        get: { store.lifecycle.quitsWithHearthstone },
                        set: { store.lifecycle.setQuitsWithHearthstone($0) }
                    ))
                    Text(HearthChrome.L(
                        "打开后，炉石进程结束时助手跟着退出。关掉主窗口不会退出。",
                        "When on, the helper quits after the Hearthstone process exits. Closing the main window does not quit."
                    ))
                    .font(.caption2)
                    .foregroundStyle(Color.mist)
                }

                section(HearthChrome.L("快捷键", "Shortcuts")) {
                    Text(HearthChrome.L(
                        "助手在前台时生效，不需要额外权限。",
                        "These work while the helper is in front. No extra permission is required."
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.mist)
                    shortcut("⌘⇧O", HearthChrome.L("显示或隐藏两侧浮窗", "Show or hide both overlays"))
                    shortcut("⌘⇧L", HearthChrome.L("中文 / English 互换", "Switch Chinese / English"))
                    shortcut("⌘⇧C", HearthChrome.L("把当前对局摘要复制到剪贴板", "Copy a snapshot of the current match"))
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .font(.caption)
        .foregroundStyle(Color.hearthText)
    }

    private var choice: Binding<Int> {
        Binding(get: { store.appearanceChoice }, set: { store.appearanceChoice = $0 })
    }
    private var motion: Binding<Int> {
        Binding(get: { store.motionLevel }, set: { store.motionLevel = $0 })
    }
    private var language: Binding<Int> {
        Binding(get: { store.interfaceLanguage }, set: { store.interfaceLanguage = $0 })
    }
    private var overlayTheme: Binding<Int> {
        Binding(get: { store.overlayTheme }, set: { store.overlayTheme = $0 })
    }
    private var layout: Binding<Int> {
        Binding(get: { store.overlayLayout }, set: { store.overlayLayout = $0 })
    }
    private var opacity: Binding<Int> {
        Binding(get: { store.overlayOpacityLevel }, set: { store.overlayOpacityLevel = $0 })
    }
    private var passthrough: Binding<Bool> {
        Binding(get: { store.isOverlayPassthrough }, set: { store.isOverlayPassthrough = $0 })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.inkLift.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.line, lineWidth: 1)
        )
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack {
            Text(keys)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(Color.onGold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gold, in: Capsule())
            Text(label)
            Spacer()
        }
    }
}
