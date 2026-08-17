// NextMeeting.swift — menu bar countdown to your next meeting.
//
// Shows one line in the macOS menu bar: the next meeting's title and how long until it starts,
// or, once it has begun, how much of it is left. Clicking opens the rest of the day.
//
//   Standup · in 34m          (upcoming)
//   ▶ Standup · 12m left      (in progress)
//   No meetings               (nothing left today)
//
// Where the data comes from: this app reads a JSON file and nothing else. It never talks to
// Google, and it never talks to an LLM. `menubar/refresh-events.sh` runs `bin/fetch-events.js`
// and writes ~/Library/Application Support/meeting-notification-bar/events.json (or
// $MNB_EVENTS_FILE, when set — see EventStore.jsonURL); this app spawns that script when the file
// goes stale. The reason for the indirection is that a GUI app inherits a minimal PATH with no
// mise/nvm/asdf shims, so it cannot find `node` itself.
//
// Deliberate choices worth knowing before editing:
//
//   * The 1-second timer only recomputes the *string*. Events are re-fetched at most every
//     REFRESH_INTERVAL seconds, plus on wake from sleep and on a system timezone change.
//     Querying the calendar every second would be 3600 API calls an hour for data that changes
//     twice a day.
//   * The title uses a monospaced-digit font. With the proportional system font the menu bar
//     visibly reflows every time a digit changes width, which reads as a bug.
//   * The dropdown activates the app (NSApp.activate) so Esc — a *local* key monitor — actually
//     gets delivered; closePanel() calls NSApp.deactivate() so focus returns to whatever the user
//     was in before, since nothing else does that for an accessory app. See openPanel/closePanel.
//   * The dropdown's height is clamped to what fits below the menu bar, and the rows scroll instead
//     of growing without bound — a busy day used to push the panel's top edge above the screen, and
//     since the panel draws at .popUpMenu level that hid the *earliest* meetings behind the menu bar
//     itself. See clampedPanelHeight, DayView's ScrollView, and openPanel().
//
// Build: bash menubar/build.sh

import AppKit
import SwiftUI

// MARK: - Tunables

/// How old events.json may get before the app re-runs the refresh script.
let REFRESH_INTERVAL: TimeInterval = 300

/// Meeting titles longer than this are truncated in the menu bar (the popover shows them whole).
let TITLE_MAX = 24

/// Under this many seconds to go, the menu bar text turns orange.
let SOON_THRESHOLD: TimeInterval = 5 * 60

/// Slack between the panel's clamped bottom edge and the edge of the visible screen (or the Dock).
/// Matches the +4 already used for the x-axis edge clamp in openPanel().
let PANEL_BOTTOM_MARGIN: CGFloat = 4

// MARK: - Model

/// One calendar event, as written by fetch-calendar-events.js.
///
/// Every field except title/start/end is optional on purpose: this app is a separate program
/// from the script that writes the file, and the two get upgraded at different times. A missing
/// key must degrade to "no join link", never to a decode failure that blanks the menu bar.
struct Event: Decodable {
    let title: String
    let start: String
    let end: String
    let attendees: [String]?
    let joinUrl: String?
    let location: String?
    let htmlLink: String?

    /// Google sends all-day events as a bare `2026-08-17` with no time. Those are not meetings
    /// you can be late to, so they are excluded from the countdown (still listed in the popover).
    var isAllDay: Bool { !start.contains("T") }

    var startDate: Date? { Self.parse(start) }
    var endDate: Date? { Self.parse(end) }

    /// The vault's fetcher emits RFC 3339 with a numeric offset (`2026-08-17T10:00:00-04:00`).
    /// Fractional seconds are tried as a fallback because Google sometimes includes them.
    static func parse(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// What the menu bar should currently say.
enum Status {
    case inProgress(Event, remaining: TimeInterval)
    case upcoming(Event, until: TimeInterval)
    case clear
    case noData

    /// Seconds until the thing the user cares about, for deciding whether to colour the text.
    var urgency: TimeInterval? {
        switch self {
        case .upcoming(_, let until): return until
        case .inProgress, .clear, .noData: return nil
        }
    }
}

// MARK: - Event store

/// Owns the parsed events and the refresh subprocess. Not thread-safe by design: every mutation
/// happens on the main queue, and the subprocess only ever hands back a value via a main-queue hop.
final class EventStore {
    private(set) var events: [Event] = []
    private(set) var lastLoad: Date?
    private(set) var lastError: String?

    /// Guards against piling up refresh processes if one hangs on a slow network.
    private var refreshing = false

    init() {}

    /// Used only by --selftest, to exercise status() against a fixed clock and fixed events.
    init(testEvents: [Event]) {
        events = testEvents
        lastLoad = Date()
    }

    /// $MNB_EVENTS_FILE overrides this when set, so another system can drive the display (or a
    /// test can point at fixture data) without forking the app. `refresh-events.sh` and
    /// `lib/paths.js` both honour the same variable — all three must agree on one path.
    static let jsonURL: URL = {
        if let override = ProcessInfo.processInfo.environment["MNB_EVENTS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/meeting-notification-bar/events.json")
    }()

    /// The refresh script, located inside this app bundle so a moved checkout still works.
    /// Bundle layout: NextMeeting.app/Contents/MacOS/NextMeeting, and the script is installed
    /// alongside at Contents/Resources/refresh-events.sh.
    static var scriptURL: URL? {
        Bundle.main.url(forResource: "refresh-events", withExtension: "sh")
    }

    /// Read the JSON off disk. Cheap enough to call on every tick, but we only call it after a
    /// refresh or when the file's mtime changes.
    func load() {
        guard let data = try? Data(contentsOf: Self.jsonURL) else {
            lastError = "no events file yet"
            return
        }
        do {
            events = try JSONDecoder().decode([Event].self, from: data)
            lastLoad = Date()
            lastError = nil
        } catch {
            // Keep whatever we had. A truncated read is better handled by waiting for the next
            // atomic replace than by clearing the display.
            lastError = "could not parse events file"
        }
    }

    var fileAge: TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.jsonURL.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// True when the cache is missing, older than REFRESH_INTERVAL, or holds a different day's
    /// events — the last case is what happens when the Mac sleeps overnight and wakes up still
    /// showing yesterday's schedule.
    var needsRefresh: Bool {
        guard let age = fileAge else { return true }
        if age > REFRESH_INTERVAL { return true }
        if let first = events.first, let start = first.startDate,
           !Calendar.current.isDateInToday(start) { return true }
        return false
    }

    /// Run refresh-events.sh, then reload. `completion` fires on the main queue either way.
    func refresh(completion: @escaping () -> Void) {
        guard !refreshing, let script = Self.scriptURL else { completion(); return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [script.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            // The script logs its own failures to
            // ~/Library/Logs/meeting-notification-bar/menubar.log and
            // leaves the previous good JSON in place, so there is nothing to do with an error
            // here except stop waiting.
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.refreshing = false
                self.load()
                completion()
            }
        }
    }

    /// Blocking refresh, for `--print`. The GUI must never call this — it would freeze the menu
    /// bar for the length of a network round trip.
    func refreshSync() {
        guard let script = Self.scriptURL else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        load()
    }

    /// Today's timed events, earliest first. All-day entries are kept out of the countdown.
    var timed: [Event] {
        events.filter { !$0.isAllDay && $0.startDate != nil }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    /// The event in progress if there is one, otherwise the next one that has not ended.
    func status(now: Date = Date()) -> Status {
        if events.isEmpty && lastLoad == nil { return .noData }
        let candidates = timed
        if let current = candidates.first(where: { e in
            guard let s = e.startDate, let en = e.endDate else { return false }
            return s <= now && en > now
        }), let end = current.endDate {
            return .inProgress(current, remaining: end.timeIntervalSince(now))
        }
        if let next = candidates.first(where: { ($0.startDate ?? .distantPast) > now }),
           let start = next.startDate {
            return .upcoming(next, until: start.timeIntervalSince(now))
        }
        return .clear
    }
}

// MARK: - Formatting

/// "34m", "1h 5m", "<1m" — the compact form a menu bar has room for.
func humanDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    if total < 60 { return "<1m" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
}

func truncate(_ s: String, _ limit: Int) -> String {
    s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
}

func clockTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}

func menuText(for status: Status) -> String {
    switch status {
    case .inProgress(let e, let remaining):
        return "▶ \(truncate(e.title, TITLE_MAX)) · \(humanDuration(remaining)) left"
    case .upcoming(let e, let until):
        return "\(truncate(e.title, TITLE_MAX)) · in \(humanDuration(until))"
    case .clear:
        return "No meetings"
    case .noData:
        return "Calendar —"
    }
}

// MARK: - Dropdown

/// Returns the clickable meeting URL for an event, or nil when there is nothing to open.
/// Kept free-standing so --selftest can check it without building a view.
func joinURL(_ event: Event) -> URL? {
    guard let link = event.joinUrl, !link.isEmpty else { return nil }
    return URL(string: link)
}

/// How tall the dropdown panel is allowed to get, given how tall its content naturally wants to be.
///
/// macOS screen coordinates have y increasing upward. `anchorMinY` is the bottom edge of the menu
/// bar — the panel's top edge sits there, flush, with no gap, by design (see the comment on
/// DropdownPanel below for why: it used to be an NSPopover, which always leaves one). The panel
/// occupies `[anchorMinY - height, anchorMinY]`, so it stays fully on screen only while
/// `height <= anchorMinY - visibleMinY`; `margin` shaves a little off that so the bottom edge
/// doesn't sit flush against the edge of the screen (or the Dock, which `visibleMinY` already
/// excludes).
///
/// Pure and screen-independent on purpose: NSScreen isn't available in the --print code path (no
/// window is ever opened there), so this is exercised directly by --selftest with injected numbers
/// instead. openPanel() and PrintOnce both call it, PrintOnce with an approximated anchor since it
/// has no real status item to measure.
func clampedPanelHeight(natural: CGFloat, anchorMinY: CGFloat, visibleMinY: CGFloat, margin: CGFloat) -> (height: CGFloat, clamped: Bool) {
    let maxHeight = max(0, anchorMinY - visibleMinY - margin)
    if natural > maxHeight {
        return (maxHeight, true)
    }
    return (natural, false)
}

/// One meeting in the dropdown. The whole row is the button — clicking anywhere on it opens the
/// meeting. An earlier version put a small "Join" link under the title and left the row itself
/// dead, which is a worse target and invites the reasonable assumption that clicking the meeting
/// does something. Rows with no link stay inert and show no hover state, so the affordance is
/// honest about which meetings can actually be opened.
struct MeetingRow: View {
    let event: Event
    let now: Date
    let onOpen: (URL) -> Void

    @State private var hovering = false

    private var live: Bool {
        guard let s = event.startDate, let e = event.endDate else { return false }
        return s <= now && e > now
    }

    var body: some View {
        let url = joinURL(event)
        Button {
            if let url { onOpen(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(event.isAllDay ? "all day" : clockTime(event.startDate ?? now))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(live ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 62, alignment: .leading)

                Text(event.title)
                    .font(.system(size: 12, weight: live ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if url != nil {
                    // Only hint at the arrow on hover: a permanent glyph on every row is noise.
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            // Without this the transparent parts of the row do not accept the click.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && url != nil ? Color.primary.opacity(0.09) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { hovering = $0 }
        .help(url != nil ? "Open \(event.title)" : event.title)
    }
}

/// The dropdown: the whole day, with the live one highlighted.
///
/// The rows sit in a `ScrollView` rather than growing the panel without limit: on a day busy
/// enough (roughly a dozen-plus meetings on a laptop screen), an unbounded panel's top edge ends up
/// above the menu bar and, because the panel draws at `.popUpMenu` level, hides the *earliest*
/// meetings behind the menu bar itself — the ones most likely to matter. openPanel() clamps the
/// hosting view's total height to what actually fits below the menu bar (see
/// `clampedPanelHeight`); giving the `ScrollView` here `.frame(maxHeight: .infinity)` while "Today",
/// the divider, and the footer keep their natural size is what lets that squeeze land on the rows
/// specifically, so Refresh/Quit stay reachable at any meeting count instead of scrolling off with
/// the list.
struct DayView: View {
    let events: [Event]
    let now: Date
    let lastLoad: Date?
    let error: String?
    let onOpen: (URL) -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if events.isEmpty {
                Text(error ?? "Nothing on the calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            MeetingRow(event: event, now: now, onOpen: onOpen)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            HStack {
                if let stamp = lastLoad {
                    Text("Updated \(clockTime(stamp))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Button("Quit", action: onQuit)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    // Row rendering and the is-this-live test now live in MeetingRow, which needs its own
    // @State for hover.
}

// MARK: - App

/// The dropdown window.
///
/// This used to be an NSPopover, which is why there was a gap between the menu bar and the
/// dropdown: a popover always draws a callout — an arrow plus the margin it needs to sit in — and
/// `show(relativeTo:preferredEdge:)` shifts the whole content away from the anchor to make room for
/// it. Neither the arrow nor that offset can be turned off through public API. A borderless panel
/// positioned by hand has neither, so the rectangle sits flush under the menu bar.
///
/// `canBecomeKey` has to be overridden: a borderless window refuses key status by default, and
/// without it the SwiftUI buttons inside never see the click.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let panel = DropdownPanel(
        contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let store = EventStore()
    private var timer: Timer?
    private var lastRendered = ""

    /// Bumped on every openPanel() so a deferred teardown from an older closePanel() call can tell
    /// it is stale and skip itself instead of nil-ing out a view that was just reopened. See
    /// closePanel().
    private var panelGeneration = 0

    /// openPanel() calls NSApp.activate() so the local Esc monitor actually receives keystrokes
    /// (see the file header). Activation is asynchronous and can itself surface a resign-active
    /// notification in the same beat, which would otherwise slam the panel shut the instant it
    /// opens. Resign notifications arriving before this deadline are ignored. See
    /// appDidResignActive().
    private var suppressResignUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        // .popUpMenu so it draws over full-screen windows; opaque so it is a plain rectangle with
        // no rounding, no arrow, and nothing showing through.
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        store.load()
        render(force: true)
        store.refresh { [weak self] in self?.render(force: true) }

        // .common mode so the countdown keeps ticking while a menu is open.
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // A sleeping Mac stops the timer; on wake the cache is almost certainly stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // The Mac's timezone can change (travel, a manual switch) without ever sleeping. The
        // cached events.json still describes the old zone's day until this fires or the next
        // REFRESH_INTERVAL tick, whichever comes first — so treat it exactly like a wake.
        NotificationCenter.default.addObserver(
            self, selector: #selector(timeZoneChanged),
            name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)

        // A panel left floating over a cmd-tabbed-to app or a different Space is a dead popover
        // that a real NSPopover would have dismissed for free. See appDidResignActive() for why
        // resigning active status doesn't always mean "close it".
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func didWake() {
        store.refresh { [weak self] in self?.render(force: true) }
    }

    @objc private func timeZoneChanged() {
        // Foundation caches the system time zone; without this, Calendar.current and any
        // DateFormatter using the implicit .current zone (clockTime, needsRefresh's
        // isDateInToday) keep answering with the old zone even after the OS has switched. Nothing
        // in this file stores a Calendar or DateFormatter across calls — both are constructed
        // fresh per call — so this reset is the only stale-cache concern.
        NSTimeZone.resetSystemTimeZone()
        store.refresh { [weak self] in self?.render(force: true) }
    }

    @objc private func appDidResignActive() {
        // openPanel() activates this accessory app so the Esc key monitor works. That activation
        // can itself generate a resign-active notification (this app briefly loses, then regains,
        // active status as macOS hands it focus) — closing on that would slam the panel shut the
        // instant it opens. Only treat this as "the user switched away" once the grace window from
        // openPanel() has passed.
        if let until = suppressResignUntil, Date() < until { return }
        closePanel()
    }

    @objc private func activeSpaceChanged() {
        closePanel()
    }

    @objc private func tick() {
        if store.needsRefresh {
            store.refresh { [weak self] in self?.render(force: true) }
        }
        render()
    }

    /// Only touch the button when the text actually changes. Reassigning an identical title once
    /// a second makes the menu bar re-layout and jitter for no reason.
    private func render(force: Bool = false) {
        let status = store.status()
        let text = menuText(for: status)
        guard force || text != lastRendered else { return }
        lastRendered = text

        let colour: NSColor
        if let urgency = status.urgency, urgency <= SOON_THRESHOLD {
            colour = .systemOrange
        } else {
            colour = .labelColor
        }
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: colour,
            ])
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        panelGeneration += 1

        // Makes this .accessory app the active app so the local Esc key monitor below actually
        // receives keystrokes. A local monitor (NSEvent.addLocalMonitorForEvents) only sees events
        // delivered to this process, and this app is never active on its own — makeKey() further
        // down grants the panel key status *within* an inactive app, which is not enough to route
        // keyboard events to it. activate(ignoringOtherApps:) (rather than the macOS-14-only
        // no-argument NSApp.activate()) keeps this working back to the app's stated macOS 13
        // minimum.
        NSApp.activate(ignoringOtherApps: true)
        // See appDidResignActive(): activation is async and can surface its own resign-active
        // notification; ignore resigns for a short window so that doesn't close the panel we just
        // opened.
        suppressResignUntil = Date().addingTimeInterval(0.35)

        let host = NSHostingView(rootView: DayView(
            events: store.events,
            now: Date(),
            lastLoad: store.lastLoad,
            error: store.lastError,
            onOpen: { [weak self] url in
                NSWorkspace.shared.open(url)
                // Close the dropdown on the way out — leaving it hanging over the browser you
                // just opened is the wrong end state.
                self?.closePanel()
            },
            onRefresh: { [weak self] in
                self?.store.refresh { self?.render(force: true) }
            },
            onQuit: { NSApp.terminate(nil) }))
        // A hairline edge, so the rectangle still reads as its own surface against a light window
        // behind it. The panel itself is square-cornered by design.
        host.wantsLayer = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.separatorColor.cgColor

        // Screen coordinates of the status item itself. anchor.minY is the bottom edge of the menu
        // bar, so subtracting the panel height puts the top edge flush against it — no gap.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        // fittingSize with no frame constraint yet is the content's *natural* height — as tall as
        // it would be with every row visible and nothing scrolling. On a busy day that can be
        // taller than the screen; clampedPanelHeight() is what turns that into a height that
        // actually fits, and the ScrollView in DayView (`.frame(maxHeight: .infinity)`) is what
        // lets the rows specifically absorb the difference instead of "Today" or the footer.
        let natural = host.fittingSize
        var size = natural
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            let (clampedHeight, _) = clampedPanelHeight(
                natural: natural.height, anchorMinY: anchor.minY, visibleMinY: visible.minY,
                margin: PANEL_BOTTOM_MARGIN)
            size.height = clampedHeight
        }
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height)
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            // A status item near the right edge would otherwise hang the panel off-screen.
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            // Belt-and-braces: size.height is already clamped to fit below the menu bar, so this
            // should be a no-op, but it costs nothing to keep the panel from going off the bottom
            // of the screen if some future edit changes the clamp above.
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installDismissMonitors()
    }

    private func closePanel() {
        // orderOut(nil) alone is enough to hide the panel. Tearing down contentView happens below,
        // deferred — closePanel() can be called synchronously from inside the SwiftUI row's own
        // onOpen action (openPanel()'s onOpen closure), while AppKit is still dispatching that
        // mouse-up through the very NSHostingView this would release. Nil-ing it out mid-dispatch
        // is a use-after-free risk.
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        removeDismissMonitors()

        // Return focus to whatever the user was in before openPanel() activated this app. Nothing
        // else does this for an .accessory app — without it, dismissing the panel (Esc, or a click
        // that isn't on another app's window) leaves this menu-bar-only app "active" with no
        // visible window, which is not a sensible place for keyboard focus to land.
        NSApp.deactivate()

        let generation = panelGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelGeneration == generation else { return }
            self.panel.contentView = nil
        }
    }

    /// A transient popover dismissed itself; a panel has to be told to. Global mouse monitors need
    /// no accessibility permission (only keyboard ones do), so a click in any other app closes it.
    private func installDismissMonitors() {
        removeDismissMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // Clicks on the status item are left alone so its own action does the toggling. Without
            // this the monitor closes the panel first and the action immediately reopens it, and
            // the menu bar item looks like it has stopped responding.
            if let frame = self.statusItemFrame(), frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // esc
            self?.closePanel()
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func statusItemFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
}

// MARK: - Self test

/// `NextMeeting --selftest` checks the two things worth checking without a GUI: that the JSON the
/// vault's fetcher actually emits decodes (including older files that predate joinUrl), and that
/// status() picks the right event against a fixed clock. Exits nonzero on the first failure.
enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ label: String, _ got: String, _ want: String) {
            if got == want {
                print("  ok    \(label): \(got)")
            } else {
                print("  FAIL  \(label): got \(got), want \(want)")
                failures += 1
            }
        }

        print("humanDuration")
        check("30s", humanDuration(30), "<1m")
        check("60s", humanDuration(60), "1m")
        check("34m", humanDuration(34 * 60), "34m")
        check("1h", humanDuration(3600), "1h")
        check("1h5m", humanDuration(3900), "1h 5m")

        print("truncate")
        check("short", truncate("Standup", 24), "Standup")
        // 23 characters plus the ellipsis = the 24 the menu bar is budgeted.
        check("long", truncate("ORGZ: Epic FHIR Prototype Kickoff", 24), "ORGZ: Epic FHIR Prototy…")

        // A file written before lib/calendar.js gained joinUrl — must still decode.
        print("decode (legacy file, no joinUrl)")
        let legacy = """
        [{"title":"ORGZ: Daily Standup","start":"2026-08-17T10:00:00-04:00",
          "end":"2026-08-17T10:30:00-04:00","attendees":["a@b.io"]}]
        """
        guard let legacyEvents = try? JSONDecoder()
            .decode([Event].self, from: Data(legacy.utf8)) else {
            print("  FAIL  legacy JSON did not decode")
            exit(1)
        }
        check("count", String(legacyEvents.count), "1")
        check("joinUrl absent", String(describing: legacyEvents[0].joinUrl), "nil")
        check("parsed start", legacyEvents[0].startDate != nil ? "yes" : "no", "yes")

        print("status")
        let fixture = """
        [{"title":"All hands offsite","start":"2026-08-17","end":"2026-08-18","attendees":[]},
         {"title":"Standup","start":"2026-08-17T10:00:00-04:00","end":"2026-08-17T10:30:00-04:00",
          "attendees":[],"joinUrl":"https://meet.google.com/xyz"},
         {"title":"Kickoff","start":"2026-08-17T14:00:00-04:00","end":"2026-08-17T15:00:00-04:00",
          "attendees":[]}]
        """
        guard let events = try? JSONDecoder().decode([Event].self, from: Data(fixture.utf8)) else {
            print("  FAIL  fixture did not decode")
            exit(1)
        }
        let store = EventStore(testEvents: events)
        check("all-day excluded from countdown", String(store.timed.count), "2")

        // What a click in the dropdown depends on: a row is clickable exactly when joinURL is
        // non-nil, so these two cases are the difference between an active and an inert row.
        print("joinURL")
        let withLink = store.timed.first { $0.title == "Standup" }!
        let noLink = store.timed.first { $0.title == "Kickoff" }!
        check("present", joinURL(withLink)?.absoluteString ?? "nil", "https://meet.google.com/xyz")
        check("absent", String(describing: joinURL(noLink)), "nil")
        check("empty string is not a link",
              String(describing: joinURL(events.first { $0.isAllDay }!)), "nil")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func at(_ s: String) -> Date { iso.date(from: s)! }

        print("clampedPanelHeight")
        // A short list: well under the cap, so it should pass through untouched.
        let short = clampedPanelHeight(natural: 200, anchorMinY: 800, visibleMinY: 40, margin: 4)
        check("short: height", String(Int(short.height)), "200")
        check("short: clamped", String(short.clamped), "false")
        // A busy day: natural height (1200) exceeds what fits below the menu bar
        // (800 - 40 - 4 = 756), so it must be capped, not just pushed up.
        let tall = clampedPanelHeight(natural: 1200, anchorMinY: 800, visibleMinY: 40, margin: 4)
        check("tall: height", String(Int(tall.height)), "756")
        check("tall: clamped", String(tall.clamped), "true")
        // Exactly at the cap: not "over", so not clamped.
        let exact = clampedPanelHeight(natural: 756, anchorMinY: 800, visibleMinY: 40, margin: 4)
        check("exact: height", String(Int(exact.height)), "756")
        check("exact: clamped", String(exact.clamped), "false")

        check("before first",  menuText(for: store.status(now: at("2026-08-17T09:26:00-04:00"))),
              "Standup · in 34m")
        check("during first",  menuText(for: store.status(now: at("2026-08-17T10:18:00-04:00"))),
              "▶ Standup · 12m left")
        check("between",       menuText(for: store.status(now: at("2026-08-17T11:00:00-04:00"))),
              "Kickoff · in 3h")
        check("during second", menuText(for: store.status(now: at("2026-08-17T14:30:00-04:00"))),
              "▶ Kickoff · 30m left")
        check("after last",    menuText(for: store.status(now: at("2026-08-17T18:00:00-04:00"))),
              "No meetings")

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `NextMeeting --print` runs the real pipeline once — refresh script, JSON read, decode, status —
/// and prints exactly what the menu bar would show, then exits. This is the diagnostic to reach for
/// when the menu bar looks wrong, because it separates "the data is wrong" from "the drawing is
/// wrong", and unlike the GUI it can be read from a terminal or a log.
enum PrintOnce {
    static func run() -> Never {
        let store = EventStore()
        store.load()
        if store.needsRefresh { store.refreshSync() }

        let status = store.status()
        print("menu bar:  \(menuText(for: status))")
        print("source:    \(EventStore.jsonURL.path)")
        if let age = store.fileAge {
            print("file age:  \(Int(age))s")
        } else {
            print("file age:  (no file)")
        }
        if let err = store.lastError { print("error:     \(err)") }
        print("events:    \(store.events.count) total, \(store.timed.count) timed")
        for e in store.timed {
            let start = e.startDate.map(clockTime) ?? "?"
            let end = e.endDate.map(clockTime) ?? "?"
            let join = (e.joinUrl?.isEmpty == false) ? "  join:\(e.joinUrl!)" : ""
            print("           \(start)–\(end)  \(e.title)\(join)")
        }

        // Same layout math openPanel() uses, run against the same events, so the height-clamping
        // fix can be proven from a terminal instead of eyeballed. There is no real status item in
        // this code path (--print never opens a window), so anchorMinY is approximated as the
        // visible frame's top edge — on the primary screen with no notch, that is the menu bar's
        // bottom edge, which is exactly what openPanel() measures from the real status item.
        let host = NSHostingView(rootView: DayView(
            events: store.events, now: Date(), lastLoad: store.lastLoad, error: store.lastError,
            onOpen: { _ in }, onRefresh: {}, onQuit: {}))
        let natural = host.fittingSize
        print("panel natural height: \(Int(natural.height))pt")
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let anchorMinY = visible.maxY
            let maxHeight = max(0, anchorMinY - visible.minY - PANEL_BOTTOM_MARGIN)
            let (finalHeight, clamped) = clampedPanelHeight(
                natural: natural.height, anchorMinY: anchorMinY, visibleMinY: visible.minY,
                margin: PANEL_BOTTOM_MARGIN)
            print("panel max height:     \(Int(maxHeight))pt (screen \(Int(screen.frame.height))pt tall)")
            print("panel final height:   \(Int(finalHeight))pt\(clamped ? "  (clamped)" : "")")
        } else {
            print("panel max height:     (no NSScreen available in --print)")
        }

        exit(store.lastError == nil ? 0 : 1)
    }
}

@main
enum NextMeeting {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if CommandLine.arguments.contains("--print") { PrintOnce.run() }
        let app = NSApplication.shared
        // Retained for the process lifetime; NSApplication holds delegate weakly.
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory = menu bar only, no Dock icon, no menu bar menus of its own.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
