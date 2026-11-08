import AppKit
import Foundation
import Observation
import ServiceManagement

/// User-configurable lifecycle automation: launch the helper at login
/// (via the standard login-item service) and quit when Hearthstone quits.
@MainActor
@Observable
final class LifecycleAutomation {
    private static let loginItemKey = "launches-at-login"
    private static let quitsWithGameKey = "quits-with-hearthstone"

    private static let hearthstoneBundleID = "unity.Blizzard Entertainment.Hearthstone"

    private(set) var launchesAtLogin: Bool {
        didSet {
            guard oldValue != launchesAtLogin else { return }
            UserDefaults.standard.set(launchesAtLogin, forKey: Self.loginItemKey)
            applyLoginItemState()
        }
    }

    private(set) var quitsWithHearthstone: Bool {
        didSet {
            guard oldValue != quitsWithHearthstone else { return }
            UserDefaults.standard.set(quitsWithHearthstone, forKey: Self.quitsWithGameKey)
        }
    }

    private var quitObserver: (any NSObjectProtocol)?

    init() {
        launchesAtLogin = UserDefaults.standard.bool(forKey: Self.loginItemKey)
        quitsWithHearthstone = UserDefaults.standard.bool(forKey: Self.quitsWithGameKey)
        installQuitObserverIfNeeded()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        launchesAtLogin = enabled
    }

    func setQuitsWithHearthstone(_ enabled: Bool) {
        quitsWithHearthstone = enabled
        installQuitObserverIfNeeded()
    }

    private func applyLoginItemState() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // registration failures (rare) leave the toggle on but ineffective;
            // keep the stored intent so the next launch retries it
            print("login item registration failed: \(error.localizedDescription)")
        }
    }

    private func installQuitObserverIfNeeded() {
        if let quitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(quitObserver)
            self.quitObserver = nil
        }
        guard quitsWithHearthstone else { return }

        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                application.bundleIdentifier == Self.hearthstoneBundleID
            else { return }
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
