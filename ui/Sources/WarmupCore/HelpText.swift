import Foundation

// App 0.6.7 Help window (F16): the guide's words, kept here so they are tested for plain words.

public enum HelpText {
    public static let title = "Warm-up Help"

    /// Every `TodayMark.Kind` case in declaration order. `Kind` is not `CaseIterable`, so this list is
    /// kept by hand; the exhaustive switch in `markCheck` fails to compile when a case is added.
    static let marks: [TodayMark.Kind] = [.confirmed, .uncertain, .problem, .missed, .skipped, .upcoming]

    private static func markCheck(_ kind: TodayMark.Kind) {
        switch kind {
        case .confirmed, .uncertain, .problem, .missed, .skipped, .upcoming: break
        }
    }

    public static var sections: [(heading: String, body: String)] {
        [
            (
                heading: "What a warm-up is",
                body: "At the times you choose, Warm-up sends one short message to each scheduled ChatGPT account. "
                    + "The aim is that, when no 5-hour usage window is running for that account, the message starts "
                    + "one, so it resets about 5 hours later while you work. Warm-up cannot confirm this; it shows "
                    + "what the provider reported at each warm-up. A warm-up is a real request and counts against "
                    + "your plan. It does not add quota."
            ),
            (
                heading: "For accounts you own",
                body: "Use Warm-up only with ChatGPT accounts you own, and check that automated requests are allowed "
                    + "under your plan's terms."
            ),
            (
                heading: "When warm-ups run",
                body: "The Mac must be awake at each time. A time that passes while the Mac is asleep or off is "
                    + "missed, and Warm-up never sends it late. Schedule shows whether a wake is booked for each coming "
                    + "time. A booked wake works with the lid open, or closed while the Mac is plugged in. On "
                    + "battery with the lid closed, macOS lets the Mac sleep again within about 30 seconds, which "
                    + "is usually too short for a warm-up. The "
                    + "schedule-wakes script in the Warm-up repository books them for 4 weeks at a time; "
                    + "with alerts on, Warm-up tells you the day before they run out."
            ),
            (
                heading: "What the marks mean",
                body: self.marks.map { "\($0.glyph)  \($0.words)" }.joined(separator: "\n")
            ),
            (
                heading: "Pausing",
                body: "Pause Scheduling stops automatic warm-ups until you resume; Warm Up Now still sends one when "
                    + "you ask. With alerts on, Warm-up reminds you once a day while scheduling stays paused for "
                    + "more than a day. If codex-router changes (Update and Restart in its menu both update it), "
                    + "automatic warm-ups are skipped until you run repin-router from the Warm-up repository, which "
                    + "checks the change and accepts it; with alerts on, Warm-up tells you right away, once "
                    + "each time it happens."
            ),
            (
                heading: "What the app stores",
                body: "Everything stays on this Mac. The app's private folder (Settings › Privacy › Show in "
                    + "Finder) holds the engine connection, a sleep journal (14 days), usage seen at each warm-up "
                    + "(60 days), account names you set, sends you marked as reviewed, and alerts waiting to be "
                    + "shown. The app's preferences hold your settings, which alerts were already shown, and when "
                    + "scheduling was first seen paused or Router's compatibility found blocked. Copied summaries "
                    + "and WarmupMenu --status and --json "
                    + "never include account names, IDs or email addresses; the engine's own commands can. The "
                    + "app makes no network requests of its own. If the Warm-up icon is missing from the menu bar, "
                    + "look in the hidden section, or in System Settings under Menu Bar."
            ),
        ]
    }
}
