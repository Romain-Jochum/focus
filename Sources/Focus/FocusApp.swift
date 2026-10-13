import AppKit
import SwiftUI
import UserNotifications

struct FocusApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let model = AppModel.shared

    init() { AppModel.shared.launch() }

    var body: some Scene {
        Window("Focus", id: "main") { MainView().environment(model) }
            .windowResizability(.contentSize)
        // No menu-bar item in the garden preview, so it can never start a real session.
        MenuBarExtra(isInserted: .constant(!AppModel.gardenPreview)) { PopoverView().environment(model) } label: { MenuBarLabel().environment(model) }
            .menuBarExtraStyle(.window)
        Window("Stats", id: "stats") { StatsView().environment(model) }
        Window("Settings", id: "settings") { SettingsView().environment(model) }
            .windowResizability(.contentSize)
    }
}

/// A state dot and the minutes left while a session runs; a quiet symbol otherwise.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRunning {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").foregroundStyle(model.stateBucket?.badge.tint ?? .gray)
                Text("\(Int((model.remaining / 60).rounded(.up)))m").monospacedDigit()
            }
        } else {
            Image(systemName: "scope")
        }
    }
}

/// Focus runs only while open. Quitting is free outside a session; during one it goes through End session, except at logout, restart and shutdown.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Banners show even while Focus is frontmost, e.g. with its window open when a session completes.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
        guard AppModel.shared.isRunning, !systemQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A session is running"
        alert.informativeText = "End it from the Focus window first."
        alert.runModal()
        return .terminateCancel
    }
}
