import Foundation

/// Maps the frontmost app, URL or window title to a distraction target.
public enum Rules {
    /// Title keywords of sites we can't read the URL of; only used when the URL is unknown.
    private static let siteTitles: [(name: String, domain: String)] = [
        ("reddit", "reddit.com"), ("netflix", "netflix.com"), ("twitch", "twitch.tv"), ("instagram", "instagram.com"),
        ("facebook", "facebook.com"), ("tiktok", "tiktok.com"), ("9gag", "9gag.com"),
    ]

    /// Browsers whose window title is matched when their URL can't be read.
    private static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]

    /// Distraction target (domain or app name) for the frontmost context, nil when it's fine.
    public static func target(app: String?, appName: String?, url: String?, title: String?, settings: Settings) -> String? {
        if let app, settings.apps.contains(app) { return appName ?? app }
        guard let url else { return app.map(browsers.contains) == true ? titleTarget(title, settings: settings) : nil }
        guard let host = host(of: url), let domain = settings.domains.first(where: { matches(host, $0) }) else { return nil }
        guard isYouTube(url) else { return domain }
        return youtubeAllowed(url) ? nil : "youtube.com"
    }

    public static func isYouTube(_ url: String?) -> Bool {
        guard let url, let host = host(of: url) else { return false }
        return matches(host, "youtube.com") || matches(host, "youtu.be")
    }

    /// At least 3 words with 2+ letters each, and not all the same word.
    public static func isValidAnswer(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
            .filter { $0.filter(\.isLetter).count >= 2 }
        return words.count >= 3 && Set(words).count > 1
    }

    /// Watch, results, playlist and embed pages are allowed; the home feed, Shorts and the rest are not.
    private static func youtubeAllowed(_ url: String) -> Bool {
        guard let path = parse(url)?.path else { return false }
        if host(of: url) == "youtu.be" { return path.count > 1 }
        return ["/watch", "/results", "/playlist", "/embed"].contains { path.hasPrefix($0) }
    }

    private static func titleTarget(_ title: String?, settings: Settings) -> String? {
        guard let t = title?.lowercased() else { return nil }
        let domain = if t == "youtube" { "youtube.com" }
            else if t.hasSuffix(" / x") { "x.com" }
            else { siteTitles.first { t.contains($0.name) }?.domain }
        return domain.flatMap { settings.domains.contains($0) ? $0 : nil }
    }

    private static func parse(_ url: String) -> URL? {
        URL(string: url.contains("://") ? url : "https://" + url)
    }

    /// Lowercased host without a leading "www." or "m.".
    private static func host(of url: String) -> String? {
        guard var host = parse(url)?.host?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
