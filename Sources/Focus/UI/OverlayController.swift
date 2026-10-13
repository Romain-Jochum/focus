import AppKit
import SwiftUI

/// The dimmed backdrop, with the card on the main screen only.
struct OverlayRoot: View {
    @Environment(AppModel.self) private var model
    let showsCard: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if showsCard, let reason = model.overlay { CheckInView(reason: reason).id(String(describing: reason)) }
        }
        .ignoresSafeArea()
    }
}

/// A panel that can become key, so the check-in field takes focus.
final class OverlayPanel: NSPanel { override var canBecomeKey: Bool { true } }

/// One borderless panel per screen at screen-saver level on every Space; each blurs what is behind it.
@MainActor final class OverlayController {
    static let shared = OverlayController()
    private var panels: [NSPanel] = []
    private var unhider: NSObjectProtocol?

    func show() {
        guard AppModel.shared.overlay != nil else { return hide() }
        // ⌘H would hide the check-in with the app: unhide while one is up.
        NSApp.unhide(nil)
        unhider = unhider ?? NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if AppModel.shared.overlay != nil { NSApp.unhide(nil) } }
        }
        if panels.isEmpty { panels = makePanels() }
        panels.forEach { $0.orderFrontRegardless() }
        panels.first { $0.screen == NSScreen.main }?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { panels.forEach { $0.orderOut(nil) }; panels = [] }

    private func makePanels() -> [NSPanel] {
        NSScreen.screens.map { screen in
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false, screen: screen)
            (panel.level, panel.collectionBehavior) = (.screenSaver, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
            (panel.isOpaque, panel.backgroundColor, panel.hasShadow) = (false, .clear, false)
            let blur = NSVisualEffectView()
            (blur.material, blur.blendingMode, blur.state) = (.fullScreenUI, .behindWindow, .active)
            let host = NSHostingView(rootView: OverlayRoot(showsCard: screen == NSScreen.main).environment(AppModel.shared))
            (host.frame, host.autoresizingMask) = (blur.bounds, [.width, .height])
            blur.addSubview(host)
            panel.contentView = blur
            return panel
        }
    }
}
