import AppKit
import SwiftUI

enum AppearanceChoice: Int, CaseIterable, Sendable {
    case system = 0
    case light = 1
    case dark = 2

    var preferredScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum InterfaceLanguage: Int, CaseIterable, Sendable {
    case chinese = 0
    case english = 1
}

enum MotionLevel: Int, CaseIterable, Sendable {
    case off = 0
    case light = 1
    case flashy = 2
}

enum OverlayThemeChoice: Int, CaseIterable, Sendable {
    case followApp = 0
    case light = 1
    case dark = 2
}

enum OverlayLayoutPreset: Int, CaseIterable, Sendable {
    case standard = 0
    case swapped = 1
    case narrow = 2
    case wide = 3
    case deckOnly = 4
    case opponentOnly = 5
}

struct HearthContext: Equatable {
    var isLight: Bool
    var language: InterfaceLanguage
    var motion: MotionLevel

    static let darkChinese = HearthContext(isLight: false, language: .chinese, motion: .light)
}

private struct HearthContextKey: EnvironmentKey {
    static let defaultValue = HearthContext.darkChinese
}

extension EnvironmentValues {
    var hearthContext: HearthContext {
        get { self[HearthContextKey.self] }
        set { self[HearthContextKey.self] = newValue }
    }
}

/// Theme and language flags read while SwiftUI bodies are evaluated.
/// `isLight` / `language` are written on the main actor and read from view code.
enum HearthChrome {
    nonisolated(unsafe) static var isLight = false
    nonisolated(unsafe) static var language: InterfaceLanguage = .chinese
    nonisolated(unsafe) static var motion: MotionLevel = .light
    /// Set during store init. Applied only after NSApp exists.
    nonisolated(unsafe) static var pendingChoice: AppearanceChoice = .dark

    @discardableResult
    static func install(_ context: HearthContext) -> HearthContext {
        isLight = context.isLight
        language = context.language
        motion = context.motion
        return context
    }

    static func context(
        choice: AppearanceChoice,
        systemIsLight: Bool,
        language: InterfaceLanguage,
        motion: MotionLevel
    ) -> HearthContext {
        let isLight: Bool
        switch choice {
        case .light: isLight = true
        case .dark: isLight = false
        case .system: isLight = systemIsLight
        }
        return HearthContext(isLight: isLight, language: language, motion: motion)
    }

    @MainActor
    static func applyAppAppearance(_ choice: AppearanceChoice) {
        // Prefer NSApplication.shared over NSApp. MatchStore.init must not call
        // this: NSApp can still be nil while the App is being constructed.
        // applicationDidFinishLaunching and later theme changes are safe.
        let app = NSApplication.shared
        switch choice {
        case .light:
            app.appearance = NSAppearance(named: .aqua)
            isLight = true
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
            isLight = false
        case .system:
            app.appearance = nil
            isLight = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
    }

    /// Shared gate for springs, pulses, and chip motion.
    enum Motion {
        static func run(_ body: () -> Void) {
            switch HearthChrome.motion {
            case .off:
                body()
            case .light:
                withAnimation(.easeOut(duration: 0.16), body)
            case .flashy:
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82), body)
            }
        }

        static var chipScaleOn: CGFloat {
            switch HearthChrome.motion {
            case .off: 1
            case .light: 1.02
            case .flashy: 1.05
            }
        }

        static var chipScaleHover: CGFloat {
            switch HearthChrome.motion {
            case .off: 1
            case .light: 1.01
            case .flashy: 1.03
            }
        }

        static func optional(_ animation: Animation) -> Animation? {
            switch HearthChrome.motion {
            case .off: nil
            case .light: animation.speed(1.4)
            case .flashy: animation
            }
        }

        static var pulseScale: CGFloat {
            switch HearthChrome.motion {
            case .off: 1
            case .light: 1.15
            case .flashy: 1.45
            }
        }
    }

    static func L(_ zh: String, _ en: String) -> String {
        language == .english ? en : zh
    }

    /// Known UI tokens (class, rarity, mechanic, stage). Card names pass through.
    static func phrase(_ zh: String) -> String {
        guard language == .english, let en = phrases[zh] else { return zh }
        return en
    }

    static func league(_ zh: String) -> String {
        switch zh {
        case "青铜": return L("青铜", "Bronze")
        case "白银": return L("白银", "Silver")
        case "黄金": return L("黄金", "Gold")
        case "铂金": return L("铂金", "Platinum")
        case "钻石": return L("钻石", "Diamond")
        case "传说": return L("传说", "Legend")
        default: return phrase(zh)
        }
    }

    private static let phrases: [String: String] = [
        "法师": "Mage", "猎人": "Hunter", "战士": "Warrior", "牧师": "Priest",
        "术士": "Warlock", "潜行者": "Rogue", "萨满祭司": "Shaman", "圣骑士": "Paladin",
        "德鲁伊": "Druid", "死亡骑士": "Death Knight", "恶魔猎手": "Demon Hunter", "中立": "Neutral",
        "标准": "Standard", "狂野": "Wild", "经典": "Classic", "幻变": "Twist",
        "未知": "Unknown", "其他": "Other",
        "随从": "Minion", "法术": "Spell", "武器": "Weapon", "任务": "Quest",
        "英雄": "Hero", "地标": "Location",
        "传说": "Legendary", "史诗": "Epic", "稀有": "Rare", "普通": "Common",
        "职业": "Class",
        "野兽": "Beast", "恶魔": "Demon", "鱼人": "Murloc", "元素": "Elemental",
        "机械": "Mech", "海盗": "Pirate", "图腾": "Totem", "野猪人": "Quilboar", "龙": "Dragon",
        "亡语": "Deathrattle", "亡语触发": "Deathrattle trigger",
        "战吼": "Battlecry", "战吼重复": "Battlecry repeat",
        "龙联动": "Dragon synergy", "机械联动": "Mech synergy", "鱼人联动": "Murloc synergy",
        "野兽联动": "Beast synergy", "海盗联动": "Pirate synergy", "恶魔联动": "Demon synergy",
        "元素联动": "Elemental synergy",
        "法术伤害": "Spell damage", "伤害法术": "Damage spell", "发现": "Discover",
        "嘲讽": "Taunt", "突袭": "Rush", "冲锋": "Charge", "圣盾": "Divine shield",
        "吸血": "Lifesteal", "剧毒": "Poisonous", "风怒": "Windfury", "潜行": "Stealth",
        "磁力": "Magnetic", "奥秘": "Secret", "过牌": "Card draw",
        "确认原始牌": "Original", "确认衍生牌": "Generated", "来源未知": "Unknown source",
        "未附着": "Not attached", "扫描中…": "Scanning…", "就绪": "Ready",
        "扫描失败（下轮重试）": "Scan failed (retrying)",
        "洗入": "Added"
    ]
}

extension Color {
    private static var light: Bool { HearthChrome.isLight }

    static var ink: Color {
        light
            ? Color(red: 0.95, green: 0.92, blue: 0.86)
            : Color(red: 12 / 255, green: 20 / 255, blue: 28 / 255)
    }

    static var inkTop: Color {
        light
            ? Color(red: 0.98, green: 0.96, blue: 0.92)
            : Color(red: 22 / 255, green: 34 / 255, blue: 44 / 255)
    }

    static var inkBottom: Color {
        light
            ? Color(red: 0.90, green: 0.86, blue: 0.78)
            : Color(red: 7 / 255, green: 12 / 255, blue: 17 / 255)
    }

    static var inkLift: Color {
        light
            ? Color(red: 0.99, green: 0.97, blue: 0.93)
            : Color(red: 20 / 255, green: 34 / 255, blue: 44 / 255)
    }

    static var panel: Color {
        light
            ? Color(red: 1, green: 0.99, blue: 0.96)
            : Color(red: 32 / 255, green: 50 / 255, blue: 62 / 255)
    }

    static var inkDeep: Color {
        light
            ? Color(red: 0.90, green: 0.86, blue: 0.78)
            : Color(red: 8 / 255, green: 14 / 255, blue: 20 / 255)
    }

    /// Always-dark strip behind card names so white type stays readable.
    static let cardStrip = Color(red: 8 / 255, green: 14 / 255, blue: 20 / 255)

    /// Dark type on gold fills and light class badges.
    static let onGold = Color(red: 28 / 255, green: 18 / 255, blue: 8 / 255)

    static var line: Color {
        light
            ? Color(red: 0.42, green: 0.32, blue: 0.18).opacity(0.38)
            : Color(red: 126 / 255, green: 154 / 255, blue: 168 / 255).opacity(0.32)
    }

    static var gold: Color {
        light
            ? Color(red: 0.62, green: 0.42, blue: 0.10)
            : Color(red: 224 / 255, green: 176 / 255, blue: 96 / 255)
    }

    static var mint: Color {
        light
            ? Color(red: 0.10, green: 0.46, blue: 0.36)
            : Color(red: 112 / 255, green: 206 / 255, blue: 176 / 255)
    }

    static var mist: Color {
        light
            ? Color(red: 0.36, green: 0.31, blue: 0.24)
            : Color(red: 158 / 255, green: 176 / 255, blue: 188 / 255)
    }

    static var goldSoft: Color { gold }
    static var mintSoft: Color { mint }
    static var mistSoft: Color { mist }
    static var lineSoft: Color { line }

    static var hearthText: Color { light ? onGold : .white }
    static var hoverWash: Color { light ? Color.black.opacity(0.05) : Color.white.opacity(0.055) }
}

/// Card-frame corners. Drawn on top of plates; they do not take hits.
struct HearthCornerMarks: View {
    var tint: Color = .gold
    var arm: CGFloat = 14

    var body: some View {
        ZStack {
            mark.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            mark.rotationEffect(.degrees(90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            mark.rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            mark.rotationEffect(.degrees(270))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private var mark: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(tint.opacity(0.9)).frame(width: arm, height: 1.5)
            Rectangle().fill(tint.opacity(0.9)).frame(width: 1.5, height: arm)
        }
        .frame(width: arm, height: arm, alignment: .topLeading)
        .padding(8)
    }
}

struct SoftAppear: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        let motion = HearthChrome.motion
        // Opacity stays 1 always. Animating parent opacity leaves later
        // ForEach inserts at opacity 0; lists that disableAnimations (the
        // opponent overlay) never recover, so the left panel looks frozen.
        content
            .offset(y: motion == .off || shown ? 0 : (motion == .flashy ? 16 : 8))
            .animation(
                motion == .off ? nil : .spring(response: motion == .flashy ? 0.48 : 0.28, dampingFraction: 0.86),
                value: shown
            )
            .onAppear { shown = true }
    }
}

extension View {
    func softAppear() -> some View { modifier(SoftAppear()) }
}

struct LivePulse: View {
    var active: Bool
    var tint: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .scaleEffect(active && pulsing ? HearthChrome.Motion.pulseScale : 1)
            .shadow(color: tint.opacity(active && pulsing ? 0.85 : 0.25), radius: active && HearthChrome.motion != .off ? 5 : 0)
            .onAppear { restart() }
            .onChange(of: active) { _, _ in restart() }
    }

    private func restart() {
        pulsing = false
        guard active, HearthChrome.motion != .off else { return }
        let duration = HearthChrome.motion == .flashy ? 0.85 : 1.2
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
