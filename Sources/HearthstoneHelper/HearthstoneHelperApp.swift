import SwiftUI

@main
struct HearthstoneHelperApp: App {
    @State private var store = MatchStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        OverlayWindowManager.shared.install(store: store)
    }

    var body: some Scene {
        WindowGroup("炉石助手", id: "main") {
            DashboardView(store: store)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra("炉石助手", systemImage: "shield.lefthalf.filled") {
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
}

private struct MenuBarContent: View {
    let store: MatchStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)

        Divider()

        Button("打开主窗口") {
            openWindow(id: "main")
        }

        Toggle("左侧浮窗 · 对手记录", isOn: Binding(
            get: { store.isOpponentOverlayVisible },
            set: { store.isOpponentOverlayVisible = $0 }
        ))

        Toggle("右侧浮窗 · 己方牌库", isOn: Binding(
            get: { store.isPlayerOverlayVisible },
            set: { store.isPlayerOverlayVisible = $0 }
        ))

        Toggle("浮窗鼠标穿透（不挡游戏）", isOn: Binding(
            get: { store.isOverlayPassthrough },
            set: { store.isOverlayPassthrough = $0 }
        ))

        Picker("浮窗透明度", selection: Binding(
            get: { store.overlayOpacityLevel },
            set: { store.overlayOpacityLevel = $0 }
        )) {
            Text("低 · 更透").tag(0)
            Text("中").tag(1)
            Text("高 · 更实").tag(2)
        }

        Divider()

        Button("退出炉石助手") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusText: String {
        switch store.status {
        case .missingLogConfig: "状态：日志未启用"
        case .notRunning: "状态：未登录（炉石未运行）"
        case .loggedIn: "状态：已登录 · 等待对局"
        case .live: "状态：游戏中"
        case .finished: "状态：本局已结束"
        }
    }
}
