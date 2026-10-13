import FocusCore

func rulesTests() {
    let settings = Settings()
    func target(_ url: String?, title: String? = nil, settings: Settings = settings) -> String? {
        Rules.target(app: "com.apple.Safari", appName: "Safari", url: url, title: title, settings: settings)
    }

    let urlCases: [(String, String?)] = [
        ("https://reddit.com/r/swift", "reddit.com"),
        ("https://old.reddit.com/", "reddit.com"),
        ("https://WWW.Reddit.com/", "reddit.com"),
        ("https://m.facebook.com/x", "facebook.com"),
        ("https://x.com/home", "x.com"),
        ("https://api.tiktok.com/", "tiktok.com"),
        ("https://news.ycombinator.com/", "news.ycombinator.com"),
        ("reddit.com/r/swift", "reddit.com"),
        ("https://ycombinator.com/", nil),
        ("https://notreddit.com/", nil),
        ("https://x.company.com/", nil),
        ("https://github.com/", nil),
        ("https://www.youtube.com/watch?v=abc", nil),
        ("https://youtube.com/results?search_query=x", nil),
        ("https://youtube.com/playlist?list=x", nil),
        ("https://www.youtube.com/embed/abc", nil),
        ("https://youtu.be/abc", nil),
        ("https://youtube.com/", "youtube.com"),
        ("https://m.youtube.com/", "youtube.com"),
        ("https://www.youtube.com/shorts/abc", "youtube.com"),
        ("https://www.youtube.com/feed/subscriptions", "youtube.com"),
        ("https://notyoutube.com/watch", nil),
    ]
    for (url, expected) in urlCases {
        check(target(url) == expected, "url \(url)")
    }

    let titleCases: [(String, String?)] = [
        ("YouTube", "youtube.com"),
        ("Some video - YouTube", nil),
        ("Reddit - Dive into anything", "reddit.com"),
        ("Home / X", "x.com"),
        ("X", nil),
        ("Netflix", "netflix.com"),
    ]
    for (title, expected) in titleCases {
        check(target(nil, title: title) == expected, "title \(title)")
    }
    check(target("https://github.com/", title: "Reddit") == nil, "title ignored when url is known")
    check(target("https://example.com/", title: "YouTube") == nil, "youtube title ignored when url is known")

    var noReddit = settings
    noReddit.domains.removeAll { $0 == "reddit.com" }
    check(target("https://reddit.com/", settings: noReddit) == nil, "domain removed from list")
    check(target(nil, title: "Reddit", settings: noReddit) == nil, "title domain removed from list")

    var slack = settings
    slack.apps = ["com.tinyspeck.slackmacgap"]
    check(Rules.target(app: "com.tinyspeck.slackmacgap", appName: "Slack", url: nil, title: nil, settings: slack) == "Slack", "app name")
    check(Rules.target(app: "com.tinyspeck.slackmacgap", appName: nil, url: nil, title: nil, settings: slack) == "com.tinyspeck.slackmacgap", "app bundle id")
    check(Rules.target(app: "com.apple.finder", appName: "Finder", url: nil, title: nil, settings: slack) == nil, "unlisted app")
    check(target(nil) == nil, "nothing frontmost")
    check(Rules.target(app: "com.apple.dt.Xcode", appName: "Xcode", url: nil, title: "twitch-client.swift", settings: settings) == nil, "titles only count in browsers")

    check(Rules.isYouTube("https://m.youtube.com/watch?v=1"), "isYouTube m.")
    check(Rules.isYouTube("youtu.be/abc"), "isYouTube youtu.be")
    check(!Rules.isYouTube("https://notyoutube.com"), "isYouTube lookalike")
    check(!Rules.isYouTube(nil), "isYouTube nil")

    let answers: [(String, Bool)] = [
        ("", false),
        ("ok", false),
        ("I am", false),
        ("I am ok", false),
        ("I am ok now", true),
        ("Yes, I drifted.", false),
        ("I drifted, checking mail", true),
        ("ok ok ok", false),
        ("Ok, ok! OK?", false),
        ("1 2 3 4", false),
        ("a b c", false),
    ]
    for (text, expected) in answers {
        check(Rules.isValidAnswer(text) == expected, "answer '\(text)'")
    }
}
