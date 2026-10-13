import AppKit
import ApplicationServices

/// Event-driven view of what's in front of the user: frontmost app, window title, browser URL, sleep and lock. Idle time is read on demand with idleSeconds().
@MainActor final class ActivitySensor {
    private(set) var app: String?
    private(set) var appName: String?
    private(set) var title: String?
    private(set) var url: String?
    private(set) var asleep = false

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var observer: AXObserver?
    private var axApp: AXUIElement?
    private var window: AXUIElement?
    private var scripts: [String: NSAppleScript] = [:]

    func start() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            self?.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        let sleepy: [(NSNotification.Name, Bool)] = [(NSWorkspace.willSleepNotification, true), (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.didWakeNotification, false), (NSWorkspace.screensDidWakeNotification, false)]
        for (name, value) in sleepy { observe(ws, name) { [weak self] _ in self?.asleep = value } }
        let dnc = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observe(dnc, Notification.Name(name)) { [weak self] _ in self?.asleep = value }
        }
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
    }

    /// Seconds since the last keyboard or mouse event.
    static func idleSeconds() -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }

    static func accessibilityOK() -> Bool { AXIsProcessTrusted() }

    /// Whether Automation (Apple Events) is granted for this browser bundle id. A missing app counts as OK.
    /// With `ask`, shows the system prompt if the user was never asked, and blocks until it is answered.
    nonisolated static func automationOK(_ bundleID: String, ask: Bool = false) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, ask)
        return status == noErr || status == procNotFound
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { body(note) }
        }
        tokens.append((center, token))
    }

    private func frontmostChanged(_ running: NSRunningApplication?) {
        // Our own overlay activates us; keep the app it is asking about.
        guard running?.processIdentifier != getpid() else { return }
        app = running?.bundleIdentifier
        appName = running?.localizedName
        attachAX(running?.processIdentifier)
        update(newApp: true)
    }

    fileprivate func axChanged() { update(newApp: false) }

    /// Re-reads the title; the URL is read only when the app or the title changed.
    private func update(newApp: Bool) {
        let next = readTitle()
        guard newApp || next != title else { return }
        title = next
        url = currentURL()
        // Right after activation the browser may not have its window front yet; read again shortly.
        if newApp, url == nil, let bundle = app, Browser.bundles.contains(bundle) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.app == bundle, self.url == nil else { return }
                self.url = self.currentURL()
            }
        }
    }

    private func currentURL() -> String? {
        app.flatMap { Browser.bundles.contains($0) ? activeURL($0) : nil }
    }

    /// Attaches an AXObserver for the app's focus and title notifications, replacing any previous one.
    private func attachAX(_ pid: pid_t?) {
        if let obs = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode) }
        observer = nil; axApp = nil; window = nil
        guard let pid, AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let obs = created else { return }
        let el = AXUIElementCreateApplication(pid), refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, el, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, el, kAXTitleChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        axApp = el
    }

    /// Title of the focused window; moves the title-change registration when the window changes.
    private func readTitle() -> String? {
        guard AXIsProcessTrusted(), let obs = observer, let win = focusedWindow() else { return nil }
        if let old = window, CFEqual(old, win) { return axString(win, kAXTitleAttribute) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = window { AXObserverRemoveNotification(obs, old, kAXTitleChangedNotification as CFString) }
        AXObserverAddNotification(obs, win, kAXTitleChangedNotification as CFString, refcon)
        window = win
        return axString(win, kAXTitleAttribute)
    }

    private func focusedWindow() -> AXUIElement? {
        guard let axApp else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func axString(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?; AXUIElementCopyAttributeValue(el, attribute as CFString, &value)
        return value as? String
    }

    /// Active tab URL of a browser's front window; only called on app or title changes.
    private func activeURL(_ bundle: String) -> String? {
        if scripts[bundle] == nil {
            scripts[bundle] = NSAppleScript(source: "tell application id \"\(bundle)\" to get URL of \(Browser.tabs[bundle] ?? "active tab") of front window")
        }
        return scripts[bundle]?.executeAndReturnError(nil).stringValue
    }
}

/// C callback on the main run loop; forwards to the sensor.
private let axCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let sensor = Unmanaged<ActivitySensor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { sensor.axChanged() }
}

/// Side effects on browsers and apps.
@MainActor enum Browser {
    static let bundles = ["com.apple.Safari", "com.google.Chrome"]
    static let tabs = ["com.apple.Safari": "current tab", "com.google.Chrome": "active tab"]

    static func closeFrontTab(_ bundleID: String) { run(bundleID, "close \(tabs[bundleID] ?? "active tab") of front window") }

    /// Hides YouTube recommendations and end screens, and turns autoplay off.
    static func injectYouTubeCSS(_ bundleID: String) {
        let js = "(function(){var s=document.getElementById('focus-hide');"
            + "if(!s){s=document.createElement('style');s.id='focus-hide';document.head.appendChild(s);}"
            + "s.textContent=\(quote(youTubeCSS));"
            + "var b=document.querySelector('.ytp-autonav-toggle-button');if(b&&b.getAttribute('aria-checked')==='true')b.click();"
            + "})();"
        if bundleID == "com.apple.Safari" {
            run(bundleID, "do JavaScript \(quote(js)) in current tab of front window")
        } else {
            run(bundleID, "execute active tab of front window javascript \(quote(js))")
        }
    }

    static func hide(_ bundleID: String) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.hide() }

    private static func run(_ bundleID: String, _ command: String) {
        NSAppleScript(source: "tell application id \"\(bundleID)\" to \(command)")?.executeAndReturnError(nil)
    }

    /// Double-quoted literal, valid in both AppleScript and JavaScript.
    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// YouTube's own element names for recommendations, end screens and Shorts (the set follows Unhook NG, https://github.com/TheArchons/unhookng).
    private static let youTubeCSS = """
        ytd-rich-grid-renderer, #secondary, #related, ytd-watch-next-secondary-results-renderer, \
        a#endpoint[title="Shorts"], ytd-shorts, grid-shelf-view-model, ytd-rich-shelf-renderer, \
        .ytp-fullscreen-grid, .ytp-ce-element, .ytp-endscreen-content { display: none !important; }
        """
}
