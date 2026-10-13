import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A 640 px screenshot of the display under the mouse, for check-in evidence. Kept in memory only. Focus's own windows are excluded, so the overlay is never in it. Nil when Screen Recording is not granted.
enum ScreenSnapshot {
    static func capture() async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }   // silent: no system prompt from a background capture
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let content = try? await SCShareableContent.current,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.width = 640; config.height = Int(640 * CGFloat(display.height) / CGFloat(display.width)); config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), configuration: config)
    }
}
