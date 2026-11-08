import SwiftUI

@main
struct HearthstoneHelperApp: App {
    @State private var store = MatchStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        OverlayWindowManager.shared.install(store: store)
    }

    var body: some Scene {
        WindowGroup(store.interfaceLanguage == InterfaceLanguage.english.rawValue ? "Hearthstone" : "炉石助手", id: "main") {
            DashboardView(store: store)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu(store.interfaceLanguage == InterfaceLanguage.english.rawValue ? "Helper" : "助手") {
                Button(HearthChrome.L("显示或隐藏浮窗", "Toggle overlays")) {
                    store.toggleOverlays()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(HearthChrome.L("切换语言", "Switch language")) {
                    store.toggleLanguage()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button(HearthChrome.L("复制当前对局", "Copy match snapshot")) {
                    store.copyMatchSnapshot()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(store.interfaceLanguage == InterfaceLanguage.english.rawValue ? "Hearthstone" : "炉石助手", systemImage: "shield.lefthalf.filled") {
            MenuBarContent(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The overlay panels and log monitor must keep running after the main
    // window closes; the menu bar item keeps the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HearthChrome.applyAppAppearance(HearthChrome.pendingChoice)
    }
}

private struct MenuBarContent: View {
    let store: MatchStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)

        Divider()

        Button {
            openWindow(id: "main")
        } label: {
            Label(HearthChrome.L("打开主窗口", "Open main window"), systemImage: "macwindow")
        }

        Picker(HearthChrome.L("外观", "Appearance"), selection: Binding(
            get: { store.appearanceChoice },
            set: { store.appearanceChoice = $0 }
        )) {
            Text(HearthChrome.L("跟随系统", "System")).tag(AppearanceChoice.system.rawValue)
            Text(HearthChrome.L("浅色", "Light")).tag(AppearanceChoice.light.rawValue)
            Text(HearthChrome.L("深色", "Dark")).tag(AppearanceChoice.dark.rawValue)
        }

        Picker(HearthChrome.L("语言", "Language"), selection: Binding(
            get: { store.interfaceLanguage },
            set: { store.interfaceLanguage = $0 }
        )) {
            Text("中文").tag(InterfaceLanguage.chinese.rawValue)
            Text("English").tag(InterfaceLanguage.english.rawValue)
        }

        Divider()

        Toggle(HearthChrome.L("左侧浮窗 · 对手记录", "Left overlay · opponent"), isOn: Binding(
            get: { store.isOpponentOverlayVisible },
            set: { store.isOpponentOverlayVisible = $0 }
        ))

        Toggle(HearthChrome.L("右侧浮窗 · 己方牌库", "Right overlay · your deck"), isOn: Binding(
            get: { store.isPlayerOverlayVisible },
            set: { store.isPlayerOverlayVisible = $0 }
        ))

        Toggle(HearthChrome.L("浮窗鼠标穿透（不挡游戏）", "Click through overlays"), isOn: Binding(
            get: { store.isOverlayPassthrough },
            set: { store.isOverlayPassthrough = $0 }
        ))

        Picker(HearthChrome.L("浮窗透明度", "Overlay opacity"), selection: Binding(
            get: { store.overlayOpacityLevel },
            set: { store.overlayOpacityLevel = $0 }
        )) {
            Text(HearthChrome.L("低 · 更透", "Low · clearer")).tag(0)
            Text(HearthChrome.L("中", "Medium")).tag(1)
            Text(HearthChrome.L("高 · 更实", "High · solid")).tag(2)
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label(HearthChrome.L("退出炉石助手", "Quit Hearthstone Helper"), systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusText: String {
        let _ = store.chromeRevision
        switch store.status {
        case .missingLogConfig: return HearthChrome.L("状态：日志未启用", "Status: logs off")
        case .notRunning: return HearthChrome.L("状态：未登录（炉石未运行）", "Status: signed out (Hearthstone isn't running)")
        case .loggedIn: return HearthChrome.L("状态：已登录 · 等待对局", "Status: signed in · waiting for a game")
        case .live: return HearthChrome.L("状态：游戏中", "Status: in game")
        case .logStalled: return HearthChrome.L("状态：对局中，但权力日志已停写", "Status: in a match, but Power.log stopped")
        case .finished: return HearthChrome.L("状态：本局已结束", "Status: match over")
        }
    }
}
