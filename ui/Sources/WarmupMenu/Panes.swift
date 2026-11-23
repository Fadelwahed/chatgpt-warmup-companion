import AppKit
import SwiftUI
import WarmupCore

// State is always shown as text plus a symbol, never by color alone; color only reinforces it.
// Every control that changes engine state asks for confirmation, runs one allowlisted command
// and shows its reply. Results that arrive later are announced to VoiceOver.

/// Speaks a short message to VoiceOver without moving focus.
@MainActor
enum Announcer {
    static func say(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

extension GlanceState {
    /// Reinforcing tint for the state; the words and symbol carry the meaning.
    var tint: Color {
        switch self {
        case .scheduled: .green
        case .running: .blue
        case .paused: .gray
        case .attention, .noUpcoming: .orange
        case .blocked: .red
        case .setupRequired, .checking, .unavailable: .secondary
        }
    }
}

extension WeekDay.Mark {
    var tint: Color {
        switch self {
        case .confirmed: .green
        case .uncertain: .orange
        case .problem: .red
        case .missed: .red
        case .skipped: .gray
        }
    }
}

struct StatusPane: View {
    @EnvironmentObject private var model: AppModel
    let openSchedule: () -> Void

    var body: some View {
        Form {
            if self.model.readIssue != nil, self.model.status != nil, let good = self.model.lastGoodRead {
                Section {
                    HStack {
                        StaleBanner(since: self.model.friendly(good))
                        Spacer()
                        Button("Refresh") { Task { await self.model.refreshAll(force: true) } }
                            .disabled(self.model.refreshing)
                    }
                }
            }
            // A state that blocks everything leads the pane (2026-11-23 UI pass).
            if ReconnectCard.shown(issue: self.model.bindingIssue) { Section { ReconnectCardView() } }
            if let issue = self.model.bindingIssue,
                let setup = EmptyState.setup(issue, executable: Bundle.main.executablePath ?? "WarmupMenu")
            {
                Section { SetupStateView(state: setup) }
            }
            Section { HeroCard(openSchedule: self.openSchedule) }
            if let report = self.model.report { ReportSection(report: report) }
            if let notice = self.model.overlapNotice {
                Section("Last result") { Label(notice, systemImage: "clock.arrow.circlepath") }
            }
            if self.model.setupNeeded, self.model.isBound { SetupCardSection() }
            if self.model.status != nil { TodaySection(openSchedule: self.openSchedule) }
            if let status = self.model.status, self.attentionShown {
                UnresolvedSection(status: status, openSchedule: self.openSchedule)
            } else if self.model.status != nil, !self.model.reviewedUnresolved.isEmpty {
                Section { ReviewedLine(count: self.model.reviewedUnresolved.count) }
            }
            if !self.model.week.isEmpty { LastSevenDaysSection(openSchedule: self.openSchedule) }
            if let effect = self.model.effect { EffectSection(effect: effect) }
            if self.model.status != nil { HealthSection() }
        }
        .formStyle(.grouped)
    }

    /// Needs attention shows while unreviewed rows exist, or while reviewed ones are listed again;
    /// otherwise reviewed rows leave one quiet line that lists them again (060-FIX1 item 8).
    private var attentionShown: Bool {
        !self.model.visibleUnresolved.isEmpty || (self.model.showReviewed && !self.model.reviewedUnresolved.isEmpty)
    }
}

/// Shown wherever values from an older read stay on screen after a failed one.
private struct StaleBanner: View {
    let since: String

    var body: some View {
        Label("Showing the last successful read, \(self.since).", systemImage: "clock.badge.exclamationmark")
    }
}

/// The verdict at a glance: state symbol, one headline, the next time once with its countdown, the
/// last slot with a way to explain it, the two actions, and when status was last read.
private struct HeroCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSchedule: () -> Void

    var body: some View {
        let glance = self.model.glance
        let headline = HeroText.headline(glance)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: glance.symbolName)
                    .font(.title)
                    .imageScale(.large)
                    .foregroundStyle(glance.state.tint)
                    // The state symbol morphs when the state changes and pulses while a change runs;
                    // both follow Reduce Motion.
                    .contentTransition(.symbolEffect(.replace))
                    .animation(self.reduceMotion ? nil : .default, value: glance.symbolName)
                    .symbolEffect(.pulse, isActive: self.model.mutating)
                    .padding(12)
                    .background(Circle().fill(glance.state.tint.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .accessibilityLabel("Warm-up: \(headline)")
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let line = HeroText.next(glance, countdown: self.countdown(at: context.date)) {
                            Label(line, systemImage: "timer").font(.callout)
                        }
                    }
                    if let last = glance.lastOutcome, let slot = glance.lastOutcomeSlot {
                        HStack(spacing: 8) {
                            Text(last).font(.callout)
                            Button("Explain") {
                                self.openSchedule()
                                Task { await self.model.explain(slot: slot) }
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Explain \(last)")
                            .accessibilityHint("Shows what happened at this time for each account")
                        }
                    }
                    ForEach(glance.notes, id: \.self) { Text($0).font(.callout) }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Refresh") { Task { await self.model.refreshAll(force: true) } }
                        .disabled(!self.model.isBound || self.model.refreshing)
                    Text(self.model.lastChecked.map { "Checked \(self.model.friendly($0))" } ?? "Not checked yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status = self.model.status {
                HStack {
                    Button("Warm Up Now…") { self.model.request(.runAll(allowSlotOverlap: false)) }
                        .accessibilityHint("Sends one request to each enabled account after you confirm")
                    if status.scheduleEnabled {
                        Button("Pause Scheduling…") {
                            self.model.request(.pause(expectedRevision: status.scheduleRevision))
                        }
                    } else {
                        Button("Resume Scheduling…") {
                            self.model.request(.resume(expectedRevision: status.scheduleRevision))
                        }
                    }
                    if self.model.mutating {
                        ProgressView().controlSize(.small).accessibilityLabel("Change in progress")
                        Text("Working…").font(.callout)
                    }
                }
                .disabled(!self.model.controlsAvailable)
                if let reason = self.model.controlsUnavailableReason, !self.model.mutating {
                    Label(reason, systemImage: "info.circle").font(.callout)
                }
                if self.model.reconcileRequired {
                    Label(
                        "The last change has an unknown outcome. Refresh before trying again.",
                        systemImage: "questionmark.diamond")
                }
            } else if self.model.refreshing {
                ProgressView().controlSize(.small).accessibilityLabel("Reading status")
            }
        }
        .padding(.vertical, 6)
    }

    private func countdown(at now: Date) -> String? {
        guard self.model.glance.state == .scheduled, let status = self.model.status, status.scheduleEnabled,
            let next = status.next, let due = Countdown.date(of: next, zone: status.schedule.zone)
        else { return nil }
        return Countdown.phrase(from: now, to: due)
    }
}

/// After an engine update: the operator's command to reconnect (F4). Warm-up never rebinds itself;
/// it only fills in the command, which runs when the operator pastes it into Terminal.
private struct ReconnectCardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reconnect to the engine", systemImage: "link.badge.plus").font(.headline)
            Text("The engine changed since Warm-up connected to it. Run this command in Terminal to reconnect.")
                .font(.callout)
            if let command = self.command {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Command") { self.model.copyText(command, confirmation: "Reconnect command copied") }
                        .accessibilityLabel("Copy reconnect command")
                        .accessibilityHint("Copies only the Terminal command. Nothing runs until you paste it.")
                    if let copied = self.model.copyConfirmation, copied.hasPrefix("Reconnect") {
                        Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                    }
                }
            } else {
                Text("Refresh to read where the engine is; the command then appears here.").font(.callout)
            }
        }
    }

    private var command: String? {
        guard let status = self.model.status, let executable = Bundle.main.executablePath else { return nil }
        return ReconnectCard.command(executable: executable, status: status)
    }
}

/// Asked once: alerts and opening at login. It goes away when answered or dismissed.
private struct SetupCardSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var alerts: AlertController

    var body: some View {
        Section("Finish setting up") {
            Toggle("Notify me when a warm-up is missed or has problems", isOn: Binding(
                get: { self.alerts.enabled }, set: { self.alerts.setEnabled($0) }))
                .disabled(!self.alerts.available || self.alerts.pending)
            Toggle("Open Warm-up at login", isOn: Binding(
                get: { self.model.launchAtLogin }, set: { self.model.setLaunchAtLogin($0) }))
            // A switch that could not change keeps the card and says why here.
            if let issue = self.alerts.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.callout) }
            if let issue = self.model.launchIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.callout) }
            HStack {
                Text("You can change both later in Settings.").font(.callout)
                Spacer()
                Button("Done") { self.model.answerSetup() }
            }
        }
    }
}

extension TodayMark.Kind {
    /// Reinforcing tint; the glyph and words carry the meaning.
    fileprivate var tint: Color {
        switch self {
        case .confirmed: .green
        case .uncertain: .orange
        case .problem, .missed: .red
        case .skipped, .upcoming: .secondary
        }
    }
}

/// Today's times as equal cells: time, mark and one line. Each opens that time on Schedule.
private struct TodaySection: View {
    @EnvironmentObject private var model: AppModel
    let openSchedule: () -> Void

    var body: some View {
        Section("Today") {
            // Marks, availability and click targets come from the date shown now (060-FIX4 item 3).
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let marks = self.model.todayMarks(at: context.date)
                if let marks, !marks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(marks, id: \.time) { mark in
                            self.cell(mark, words: mark.cellWords(countdown: self.countdown(mark, at: context.date)))
                        }
                    }
                } else {
                    Text(TodayMark.emptyText(available: marks != nil)).font(.callout)
                }
            }
        }
    }

    private func cell(_ mark: TodayMark, words: String) -> some View {
        Button {
            self.open(mark)
        } label: {
            VStack(spacing: 4) {
                Text(mark.time).font(.headline.monospacedDigit())
                Text(mark.kind.glyph).font(.title3).foregroundStyle(mark.kind.tint)
                Text(words).font(.callout).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("\(mark.time) \(words). Show details.")
        .accessibilityLabel("Open \(mark.time) details")
        .accessibilityValue(words)
    }

    /// The countdown, only for the next time when it is the mark's own slot.
    private func countdown(_ mark: TodayMark, at now: Date) -> String? {
        guard mark.kind == .upcoming, let status = self.model.status, status.scheduleEnabled, let next = status.next,
            next.slot == mark.slot, let due = Countdown.date(of: next, zone: status.schedule.zone)
        else { return nil }
        return Countdown.phrase(from: now, to: due)
    }

    /// Opens the slot of the date the mark was shown for.
    private func open(_ mark: TodayMark) {
        guard let slot = mark.slot else { return }
        self.openSchedule()
        Task { await self.model.explain(slot: slot) }
    }
}

/// One section over the last seven days: the sentence, the strip with clickable marks, and the
/// breakdown in a disclosure.
private struct LastSevenDaysSection: View {
    @EnvironmentObject private var model: AppModel
    let openSchedule: () -> Void
    @State private var details = false

    var body: some View {
        Section {
            if let report = self.model.weekReport { Text(report.headline).font(.headline) }
            if let stale = self.model.weekStaleLine { Text(stale).font(.callout) }
            WeekStrip(days: self.model.week) { slot in
                self.openSchedule()
                Task { await self.model.explain(slot: slot) }
            }
            if self.model.weekTruncated {
                Text("Only the most recent results fit; older days may be incomplete.").font(.callout)
            }
            if let report = self.model.weekReport {
                DisclosureGroup("Details", isExpanded: self.$details) {
                    ForEach(Array(report.details.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                    HStack {
                        Button("Copy Weekly Report") { self.model.copyWeekReport() }
                            .accessibilityHint("Copies counts and reasons; accounts are numbered, not named")
                        if let copied = self.model.copyConfirmation, copied.hasPrefix("Weekly") {
                            Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                        }
                    }
                }
            }
        } header: {
            Text("Last 7 days")
        } footer: {
            WeekLegend(days: self.model.week)
        }
    }
}

/// "3 reviewed possible sends · Show", in place of Needs attention when only reviewed rows exist.
private struct ReviewedLine: View {
    @EnvironmentObject private var model: AppModel
    let count: Int

    var body: some View {
        let noun = "reviewed possible send\(self.count == 1 ? "" : "s")"
        HStack(spacing: 4) {
            Text("\(self.count) \(noun) ·").foregroundStyle(.secondary)
            Button("Show") { self.model.showReviewed = true }
                .buttonStyle(.link)
                .accessibilityLabel("Show \(self.count) \(noun)")
        }
        .font(.callout)
    }
}

/// Possible sends without a recorded outcome that are not marked as reviewed, grouped by slot; the
/// list folds away past three groups. Reviewed rows are listed again on request (F8).
private struct UnresolvedSection: View {
    @EnvironmentObject private var model: AppModel
    let status: EngineStatus
    let openSchedule: () -> Void
    @State private var expanded = false

    var body: some View {
        let today = FriendlyTime.today(zone: self.status.schedule.zone)
        let visible = self.model.visibleUnresolved
        let groups = UnresolvedGroup.make(visible, today: today)
        Section("Needs attention") {
            if !visible.isEmpty {
                HStack {
                    Label(
                        UnresolvedText.line(count: visible.count, truncated: self.status.unresolvedTruncated == true),
                        systemImage: "questionmark.diamond")
                    Spacer()
                    Button("Mark as Reviewed") { self.model.markReviewed() }
                        .controlSize(.small)
                        .help("Hides these rows in Warm-up only. Nothing is sent to the engine.")
                        .accessibilityLabel(
                            "Mark \(visible.count) possible send\(visible.count == 1 ? "" : "s") as reviewed")
                }
                if groups.count <= 3 {
                    self.rows(groups)
                } else {
                    DisclosureGroup("Show \(groups.count) times", isExpanded: self.$expanded) { self.rows(groups) }
                }
            }
            if let issue = self.model.saveIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout)
            }
            self.reviewed(today: today)
        }
    }

    private func rows(_ groups: [UnresolvedGroup]) -> some View {
        ForEach(groups) { group in
            HStack {
                Text(group.text).font(.callout)
                Spacer()
                if let slot = group.slot {
                    Button("Explain") {
                        self.openSchedule()
                        Task { await self.model.explain(slot: slot) }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Explain \(group.text)")
                }
            }
        }
    }

    /// "Show reviewed" lists hidden rows again; each button sets the value its title names.
    @ViewBuilder
    private func reviewed(today: String?) -> some View {
        let reviewed = self.model.reviewedUnresolved
        if !reviewed.isEmpty {
            if self.model.showReviewed {
                ForEach(UnresolvedGroup.make(reviewed, today: today)) { group in
                    Label("\(group.text) · reviewed", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Hide") { self.model.showReviewed = false }
                    .buttonStyle(.link)
                    .accessibilityLabel("Hide reviewed possible sends")
            } else {
                Button("Show reviewed (\(reviewed.count))") { self.model.showReviewed = true }
                    .buttonStyle(.link)
                    .accessibilityLabel("Show \(reviewed.count) reviewed possible sends")
            }
        }
    }
}

/// "Did it help?": whether warm-ups start a fresh short window, from the usage headers at each send,
/// with progress toward a decision, the decision card (F1) and the per-send list.
private struct EffectSection: View {
    @EnvironmentObject private var model: AppModel
    let effect: EffectState
    @State private var details = false

    var body: some View {
        let summary = self.effect.summary
        Section {
            Text(summary.verdict).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: self.effect.progressFraction)
                    .controlSize(.small)
                    .accessibilityLabel("Measurement progress")
                    .accessibilityValue(self.effect.progress)
                Text(self.effect.progress).font(.callout)
            }
            if let decision = self.effect.decision {
                DecisionCard(decision: decision)
            } else if self.effect.countFromLabel == nil {
                Text(EffectReport.noCountFrom).font(.callout)
            }
            if summary.total > 0 || !self.effect.rows.isEmpty {
                DisclosureGroup("Details", isExpanded: self.$details) {
                    ForEach(summary.lines, id: \.self) { Text($0).font(.callout) }
                    Text(EffectReport.stopRule).font(.callout)
                    ForEach(self.effect.rows) { row in EffectRowView(row: row) }
                    HStack {
                        Button("Copy Effect Report") { self.model.copyEffectReport() }
                            .accessibilityHint("Copies counts and sends; accounts are numbered, not named")
                        if let copied = self.model.copyConfirmation, copied.hasPrefix("Effect") {
                            Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                        }
                    }
                }
            }
        } header: {
            Text("Did it help?")
        } footer: {
            Text(EffectReport.footer).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The decision once enough sends are measured. Only "turn the schedule off" offers Pause
/// Scheduling…, through the same confirmed action as the hero.
private struct DecisionCard: View {
    @EnvironmentObject private var model: AppModel
    let decision: EffectDecision

    var body: some View {
        HStack {
            Label(self.decision.text, systemImage: self.symbol).font(.callout.weight(.semibold))
            Spacer()
            if self.decision.offersPause, let status = self.model.status, status.scheduleEnabled {
                Button("Pause Scheduling…") { self.model.request(.pause(expectedRevision: status.scheduleRevision)) }
                    .modifier(ActionGate(model: self.model, help: "Asks for confirmation, then pauses scheduling"))
                    .accessibilityLabel("Pause scheduling, as the measurement suggests")
            }
        }
    }

    private var symbol: String {
        switch self.decision {
        case .keep: "checkmark.circle"
        case .stop: "pause.circle"
        case .undecided: "questionmark.circle"
        }
    }
}

/// One send: time, account, effect and when its window reset.
private struct EffectRowView: View {
    let row: EffectRow

    var body: some View {
        HStack(spacing: 8) {
            Text(self.row.time).monospacedDigit()
            Text(self.row.label).fontWeight(.semibold)
            Text(self.row.effectWords)
            Spacer(minLength: 4)
            if !self.row.resetText.isEmpty { Text(self.row.resetText).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Seven day columns, oldest first. Each mark opens that time's explanation.
private struct WeekStrip: View {
    let days: [WeekDay]
    let open: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(self.days) { day in
                let isToday = day.id == self.days.last?.id
                VStack(spacing: 6) {
                    Text(Wording.weekday(day.weekday)).font(.caption.weight(.semibold))
                    Text(String(day.date.suffix(2))).font(.caption.monospacedDigit())
                    Divider()
                    if day.slots.isEmpty {
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    ForEach(day.slots) { slot in
                        Button {
                            self.open("\(day.date)T\(slot.time)")
                        } label: {
                            VStack(spacing: 1) {
                                Image(systemName: slot.mark.symbolName).foregroundStyle(slot.mark.tint)
                                Text(slot.time).font(.caption.monospacedDigit())
                            }
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(slot.time) \(slot.mark.words). Show details.")
                        .accessibilityLabel("\(slot.time) \(slot.mark.words)")
                        .accessibilityHint("Shows what happened")
                    }
                    if day.manualRuns > 0 {
                        Text("+\(day.manualRuns) manual").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isToday ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isToday ? Color.accentColor.opacity(0.5) : .clear))
                .accessibilityElement(children: .contain)
                .accessibilityLabel((isToday ? "Today, " : "") + day.spoken)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Leading-aligned, listing only the marks present this week.
private struct WeekLegend: View {
    let days: [WeekDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(WeekDay.marksPresent(self.days), id: \.self) { mark in
                    Label(mark.words.capitalizedFirst, systemImage: mark.symbolName)
                        .labelStyle(LegendLabelStyle(tint: mark.tint))
                }
                if self.days.contains(where: { $0.slots.isEmpty }) {
                    Label("No record", systemImage: "circle.dashed").labelStyle(LegendLabelStyle(tint: .secondary))
                }
            }
            Text(self.hint)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hint: String {
        let click = "Click a time to see what happened."
        return self.days.contains { $0.manualRuns > 0 } ? "+N manual: manual warm-ups that day. \(click)" : click
    }
}

private struct LegendLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(self.tint)
            configuration.title
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { self.prefix(1).uppercased() + self.dropFirst() }
}

/// Plain checks in one collapsed row: "All checks pass" or the first check that needs a look.
private struct HealthSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        if let status = self.model.status {
            let rows = HealthCheck.rows(
                status: status, observedAt: self.model.lastObservedAt, wake: self.model.wake,
                nextLocalAdmission: self.model.nextLocalAdmission)
            let fine = HealthCheck.allFine(rows)
            Section {
                DisclosureGroup(isExpanded: self.$expanded) {
                    ForEach(rows) { row in
                        LabeledContent {
                            Text(row.value).multilineTextAlignment(.trailing)
                        } label: {
                            // Orange on the symbol only: orange text is about 2.2:1 on a light background.
                            Label(row.title, systemImage: row.symbolName)
                                .labelStyle(LegendLabelStyle(tint: row.level == .warning ? .orange : .primary))
                        }
                    }
                } label: {
                    Label(HealthCheck.collapsed(rows), systemImage: fine ? "checkmark.seal" : "exclamationmark.triangle")
                }
            } header: {
                Text("Health")
            }
        }
    }
}

/// Start-up choices, alerts, measurement, privacy and the engine connection, behind Cmd-comma.
struct SettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Warm-up at login", isOn: Binding(
                    get: { self.model.launchAtLogin }, set: { self.model.setLaunchAtLogin($0) }))
                    .accessibilityHint("Adds Warm-up to Login Items so the menu-bar icon and alerts start with your Mac")
                if let issue = self.model.launchIssue { Label(issue, systemImage: "exclamationmark.triangle") }
                if self.model.launchPending {
                    Label(
                        "Waiting for approval: allow Warm-up in System Settings > General > Login Items.",
                        systemImage: "hourglass")
                }
                Picker("Menu bar shows", selection: self.$model.menuBarMode) {
                    Text("Icon only").tag(MenuBarMode.iconOnly)
                    Text("Time left").tag(MenuBarMode.timeLeft)
                    Text("Next time").tag(MenuBarMode.nextTime)
                }
            }
            AlertsSection()
            MeasurementSection()
            PrivacySection()
            AdvancedSection()
        }
        .formStyle(.grouped)
    }
}

private struct AlertsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var alerts: AlertController

    var body: some View {
        Section("Alerts") {
            Toggle("Notify me when a warm-up is missed or has problems", isOn: Binding(
                get: { self.alerts.enabled }, set: { self.alerts.setEnabled($0) }))
                .disabled(!self.alerts.available || !self.model.isBound || self.alerts.pending)
                .accessibilityHint("Off by default. Shows a notification when a scheduled warm-up is missed or finishes with problems")
            if self.alerts.pending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your answer in the macOS notification prompt…").font(.callout)
                }
            }
            Text("Warm-up checks after each scheduled time and every 15 minutes while it runs.").font(.callout)
            if let issue = self.alerts.issue {
                Label(issue, systemImage: "bell.slash")
            } else if !self.alerts.available {
                Label("Alerts need the installed Warm-up app.", systemImage: "info.circle")
            } else if !self.model.isBound {
                Label("Alerts need a verified engine connection.", systemImage: "info.circle")
            }
        }
    }
}

/// The "count from" day for "Did it help?" (F1), picked in the schedule's zone. Stored on this Mac
/// only; nothing is sent to the engine.
private struct MeasurementSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let zone = self.zone
        Section("Measurement") {
            HStack {
                DatePicker(
                    "Count \"Did it help?\" from", selection: self.day(zone: zone), in: ...Date(),
                    displayedComponents: .date
                )
                .environment(\.timeZone, zone)
                Button("Clear") { self.model.setCountFrom(nil) }
                    .disabled(self.model.effectCountFromDay == nil)
                    .accessibilityLabel("Clear the count from date")
            }
            if self.model.effectCountFromDay == nil {
                HStack {
                    Text("Not set: counting the last \(EffectReport.periodDays) days.").font(.callout)
                    Spacer()
                    Button("Count From Today") { self.model.setCountFrom(ClockTime.day(from: Date(), zone: zone)) }
                }
            }
            Text(EffectReport.stopRule).font(.callout)
        }
    }

    private var zone: TimeZone {
        self.model.status.flatMap { TimeZone(identifier: $0.schedule.zone) } ?? .current
    }

    /// Shows the stored day (today while none is set); a pick sends the picked day.
    private func day(zone: TimeZone) -> Binding<Date> {
        Binding(
            get: {
                guard let day = self.model.effectCountFromDay,
                    let start = EffectReport.countFromStart(day: day, zone: zone.identifier)
                else { return Date() }
                return Date(timeIntervalSince1970: Double(start) / 1000)
            },
            set: { self.model.setCountFrom(ClockTime.day(from: $0, zone: zone)) })
    }
}

private struct PrivacySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Privacy") {
            Toggle("Hide account names", isOn: self.$model.hideAccountNames)
                .accessibilityHint("Shows Account 1, Account 2 instead of names on screen and in the menu")
            Text("Warm-up makes no network requests; the engine sends the warm-ups.").font(.callout)
            Text(
                "It keeps private files on this Mac: the engine connection, a sleep journal (14 days), a usage log "
                    + "(60 days), account nicknames and reviewed sends."
            )
            .font(.callout)
            Text("Copied summaries never include account names or IDs.").font(.callout)
            if let folder = BindingStore.defaultStore()?.directory {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .accessibilityLabel("Show Warm-up's private folder in Finder")
            }
        }
    }
}

private struct AdvancedSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var wakeHelp = false

    var body: some View {
        Section("Advanced") {
            if ReconnectCard.shown(issue: self.model.bindingIssue) {
                ReconnectCardView()
            } else if let issue = self.model.bindingIssue {
                Label(issue.description, systemImage: "lock.trianglebadge.exclamationmark")
            } else {
                Label("Engine connection: verified", systemImage: "checkmark.seal")
            }
            LabeledContent("Version", value: self.model.versionLine)
            if let issue = self.model.readIssue { Label(issue, systemImage: "exclamationmark.triangle") }
            HStack {
                Button("Copy Status Summary") { self.model.copyStatusDiagnostic() }
                    .disabled(self.model.status == nil || self.model.bindingIssue != nil)
                    .accessibilityHint("Copies codes, counts and local times only. No account names or identifiers.")
                if let copied = self.model.copyConfirmation, copied.hasPrefix("Status") {
                    Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                }
            }
            DisclosureGroup("How to wake the Mac for a warm-up", isExpanded: self.$wakeHelp) { WakeReadinessView() }
        }
    }
}

/// Whether the Mac will be awake for the next slot, with a copyable command to schedule a wake.
private struct WakeReadinessView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch self.model.wake {
        case let .ready(wakeAt):
            Label("A wake is set for \(wakeAt), before the next warm-up.", systemImage: "alarm")
        case .notScheduled:
            let admission = self.model.nextLocalAdmission ?? "the next warm-up"
            Label("No wake is set before \(admission).", systemImage: "moon.zzz")
            Text("If the Mac is asleep at that minute, the warm-up is missed. Keep it awake and plugged in, or add a repeating wake. macOS keeps one repeating wake, so it can cover only one time a day. A closed lid on battery power still sleeps.")
                .font(.callout)
            if let local = self.model.nextLocalAdmission {
                let command = WakeReadiness.suggestedCommand(admission: local)
                HStack {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Command") { self.model.copyText(command, confirmation: "Wake command copied") }
                        .accessibilityHint("Copies a Terminal command that wakes the Mac 5 minutes before this time every day. It asks for an administrator password.")
                }
                if let copied = self.model.copyConfirmation, copied.hasPrefix("Wake") {
                    Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                }
                if self.model.wakeRepeatExists {
                    Label(
                        "This Mac already has a repeating wake or power schedule. This command replaces it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                }
            }
        case .unknown:
            Label("The Mac's wake schedule could not be read.", systemImage: "questionmark.circle")
        }
    }
}

struct ReportSection: View {
    @EnvironmentObject private var model: AppModel
    let report: OperationReport

    var body: some View {
        Section {
            HStack {
                Label(self.report.headline, systemImage: Self.symbol(self.report.kind))
                    .accessibilityLabel("Result: \(self.report.headline)")
                Spacer()
                Button("Dismiss") { self.model.dismissReport() }
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss result")
            }
            ForEach(Array(self.report.details.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
            if let overlap = self.report.overlap {
                Button("Run Anyway…") { Task { await self.model.runAnyway(self.report) } }
                    .disabled(!self.model.controlsAvailable)
                    .accessibilityHint("Checks that the warm-up due at \(overlap.admission) is still next, then asks for confirmation")
            }
        } header: {
            Text("Last result" + (self.model.reportAt.map { ", \(self.model.friendly($0))" } ?? ""))
        }
    }

    static func symbol(_ kind: OperationReport.Kind) -> String {
        switch kind {
        case .completed: "checkmark.circle"
        case .partial: "exclamationmark.circle"
        case .refused: "xmark.octagon"
        case .busy: "hourglass"
        case .noWork: "minus.circle"
        case .conflict: "arrow.triangle.2.circlepath.circle"
        case .overlap: "clock.badge.exclamationmark"
        case .unknown: "questionmark.diamond"
        }
    }
}

struct SchedulePane: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var earlier = false
    /// The selected row, by occurrence: the two fall-back 01:30s share one slot but not one row.
    @State private var selectedRow: String?
    /// Rows from "Earlier this week" are tagged with this prefix and their slot.
    private static let pastPrefix = "past:"

    var body: some View {
        // HStack, not HSplitView: on the host the split view let the List take its full content
        // height, which pushed the schedule below the window (found in U4 inspection).
        HStack(spacing: 0) {
            List(selection: self.rowSelection) {
                if self.model.projectionStale, let good = self.model.projectionReadAt {
                    StaleBanner(since: self.model.friendly(good))
                }
                if let issue = self.model.projectionIssue, self.model.projection != nil {
                    Label(issue, systemImage: "exclamationmark.triangle")
                }
                if let projection = self.model.projection {
                    self.summarySection(projection)
                    self.todaySection(projection)
                    self.comingSection(projection)
                    self.earlierSection(today: projection.localDate)
                } else if let issue = self.model.projectionIssue ?? self.model.readIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                    Button("Refresh") { Task { await self.model.refreshAll(force: true) } }
                } else {
                    Text(self.model.isBound ? "Loading schedule…" : "Setup required")
                }
                if self.model.supports("schedule_vacations") || self.model.supports("schedule_undo") {
                    VacationSection(input: self.model.vacationInput)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SlotDetail().frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: self.$editing) {
            ScheduleEditSheet(input: self.model.editorInput).environmentObject(self.model)
        }
        .onAppear { self.selectInitial() }
        .onChange(of: self.model.projection == nil) { self.selectInitial() }
        .onChange(of: self.model.selectedSlot) { _, slot in
            if let slot, self.isPast(slot) { self.earlier = true }
        }
        .onChange(of: self.model.explanation?.explanation.slot) { _, slot in
            if let slot { Announcer.say("Details loaded for \(FriendlyTime.slot(slot, today: self.model.projection?.localDate))") }
        }
        .onChange(of: self.model.proposalIssue) { _, issue in
            if let issue { Announcer.say(issue) }
        }
        .onChange(of: self.model.proposal == nil) { _, isNil in
            if !isNil { Announcer.say("Proposed schedule ready. It is not saved.") }
        }
    }

    /// "08:00, 13:00, 18:00 · every day" with Edit Times…, then spacing advice (F7).
    private func summarySection(_ projection: ScheduleProjection) -> some View {
        Section {
            HStack {
                Text(self.summary(projection)).font(.callout)
                Spacer()
                Button("Edit Times…") { self.editing = true }
                    .disabled(!self.model.isBound)
                    .accessibilityHint("Opens the time editor. Nothing changes until you preview and save.")
            }
            ForEach(self.spacingAdvice, id: \.self) { advice in
                Label(advice, systemImage: "exclamationmark.triangle").font(.callout)
            }
            if let notice = projection.zoneNotice {
                Label("Time zone changed from \(notice.previousZone) to \(notice.zone).", systemImage: "globe")
            }
            if !projection.scheduleEnabled { Label("Scheduling is paused.", systemImage: "pause.circle") }
        }
    }

    /// Today's times with the week strip's mark or a countdown (X6).
    @ViewBuilder
    private func todaySection(_ projection: ScheduleProjection) -> some View {
        if let day = projection.days.first(where: { $0.date == projection.localDate }) {
            let marks = self.model.week.first { $0.date == day.date }?.slots ?? []
            Section {
                if let exclusion = day.exclusion {
                    Label(ScheduleRowText.excluded(exclusion), systemImage: "calendar.badge.minus")
                } else if day.admissions.isEmpty {
                    Text("No warm-ups")
                }
                ForEach(day.admissions) { admission in
                    let mark = marks.first { $0.time == String(admission.slot.suffix(5)) }?.mark
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let now = Int(context.date.timeIntervalSince1970 * 1000)
                        AdmissionRow(
                            admission: admission,
                            words: ScheduleRowText.words(
                                admission: admission, mark: mark, isNext: admission.next == true, now: now))
                    }
                    .tag(admission.id)
                    .accessibilityHint("Shows what happened at this time")
                }
            } header: {
                Text(self.dayTitle(day, zone: projection.zone))
            }
        }
    }

    /// Tomorrow and the following days: one line per day that repeats the recurring times (X6).
    @ViewBuilder
    private func comingSection(_ projection: ScheduleProjection) -> some View {
        let rows = ScheduleFold.days(
            projection: projection, recurring: self.model.status?.schedule.times ?? [],
            today: FriendlyTime.today(zone: projection.zone))
        if !rows.isEmpty {
            Section("Coming days") {
                ForEach(rows) { row in
                    switch row {
                    case let .folded(_, text):
                        Text(text)
                    case let .expanded(day):
                        Text(self.dayTitle(day, zone: projection.zone)).font(.headline)
                        if let exclusion = day.exclusion {
                            Label(self.offText(exclusion), systemImage: "calendar.badge.minus")
                        } else if day.admissions.isEmpty {
                            Text("No warm-ups")
                        }
                        ForEach(day.admissions) { admission in
                            AdmissionRow(admission: admission)
                                .padding(.leading, 12)
                                .tag(admission.id)
                                .accessibilityHint("Shows what happened at this time")
                        }
                    }
                }
            }
        }
    }

    /// Past days from the week strip, so its links for past times land on a row.
    @ViewBuilder
    private func earlierSection(today: String) -> some View {
        let days = self.model.week.filter { $0.date < today }
        if !days.isEmpty {
            Section {
                DisclosureGroup("Earlier this week", isExpanded: self.$earlier) {
                    ForEach(days.reversed()) { day in
                        // Every row in this List needs an identity unique across days (0.6.1).
                        Text(ScheduleDayName.name(day.date, today: today)).font(.headline).id("day:\(day.date)")
                        if day.slots.isEmpty {
                            Text("No warm-ups recorded").foregroundStyle(.secondary).id("empty:\(day.date)")
                        }
                        ForEach(day.slots) { slot in
                            HStack {
                                Text(slot.time).monospacedDigit()
                                Spacer()
                                Text(ScheduleRowText.past(slot.mark))
                            }
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Shows what happened at this time")
                            .tag(Self.pastPrefix + slot.id)
                        }
                    }
                }
            }
        }
    }

    private var spacingAdvice: [String] {
        SpacingAdvice.make(
            times: self.model.status?.schedule.times ?? [],
            windowMinutes: SpacingAdvice.observedWindow(log: self.model.usageLog))
    }

    /// Selecting a row explains its slot; a slot chosen elsewhere selects its first row.
    private var rowSelection: Binding<String?> {
        Binding(
            get: {
                if let row = self.selectedRow, self.slot(for: row) == self.model.selectedSlot { return row }
                let rows = self.model.projection?.days.flatMap(\.admissions) ?? []
                if let row = rows.first(where: { $0.slot == self.model.selectedSlot }) { return row.id }
                guard let slot = self.model.selectedSlot, self.isPast(slot) else { return nil }
                return Self.pastPrefix + slot
            },
            set: { row in
                self.selectedRow = row
                if let row, let slot = self.slot(for: row) { Task { await self.model.explain(slot: slot) } }
            })
    }

    private func slot(for row: String) -> String? {
        if row.hasPrefix(Self.pastPrefix) { return String(row.dropFirst(Self.pastPrefix.count)) }
        return self.model.projection?.days.flatMap(\.admissions).first { $0.id == row }?.slot
    }

    /// A slot listed under "Earlier this week".
    private func isPast(_ slot: String) -> Bool {
        guard let today = self.model.projection?.localDate else { return false }
        let date = String(slot.prefix(10))
        let time = String(slot.suffix(5))
        return date < today
            && self.model.week.contains { $0.date == date && $0.slots.contains { $0.time == time } }
    }

    /// On open, select the unseen problem, else the latest finished time today, else the next one
    /// (X5). A time already chosen (from Overview or the menu) is kept.
    private func selectInitial() {
        guard self.model.selectedSlot == nil, let projection = self.model.projection else { return }
        let today = projection.days.first { $0.date == projection.localDate }?.admissions ?? []
        let now = Int(Date().timeIntervalSince1970 * 1000)
        guard
            let slot = ScheduleSelection.initial(
                unseenProblem: self.model.glance.unseenProblemSlot, today: today, now: now)
        else { return }
        self.model.selectedSlot = slot
        Task { if self.model.selectedSlot == slot { await self.model.explain(slot: slot) } }
    }

    /// "08:00, 13:00, 18:00 · every day", with the zone only when it is not the Mac's.
    private func summary(_ projection: ScheduleProjection) -> String {
        let times = self.model.status?.schedule.times.joined(separator: ", ") ?? ""
        let days = projection.weekdays.count == 7 ? "every day" : projection.weekdays.map(Wording.weekday).joined(separator: ", ")
        let zone = projection.zone == TimeZone.current.identifier ? "" : " · times in \(projection.zone)"
        return "\(times) · \(days)\(zone)"
    }

    /// "Today, Mon 23 Nov · 3 warm-ups".
    /// "Today, Sun 22 Nov · 3 warm-ups": "Today" only for the current date in `zone` (060-FIX6 item 5).
    private func dayTitle(_ day: ProjectedDay, zone: String) -> String {
        ScheduleDayName.title(day.date, count: day.attemptsPerAccount, today: FriendlyTime.today(zone: zone))
    }

    private func offText(_ exclusion: String) -> String {
        exclusion == "vacation" ? "Off: time off" : exclusion == "weekday" ? "Off: not a scheduled day" : "Off: \(Wording.code(exclusion))"
    }
}

/// The time editor in a sheet (X4): Add, Move, Remove, Days; Preview; the proposal with its marks;
/// then Save… (the existing confirmed save) or Cancel (drops the unsaved proposal).
private struct ScheduleEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var input: EditorInput
    @Environment(\.dismiss) private var dismiss
    @State private var openedAt = Date()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Edit times") { ScheduleEditor(input: self.input) }
                if let proposal = self.model.proposal {
                    Section {
                        Label("Proposed schedule, not saved", systemImage: "eye")
                        if let summary = self.model.proposalEdit?.summary { Text(summary).font(.callout) }
                    }
                    let current = self.model.proposalBaseline
                    let added = ProposalDiff.added(current: current, proposed: proposal.days)
                    let removed = ProposalDiff.removed(current: current, proposed: proposal.days)
                    ForEach(proposal.days) { day in
                        Section(self.dayTitle(day, today: proposal.localDate)) {
                            if let exclusion = day.exclusion {
                                Label(ScheduleRowText.excluded(exclusion), systemImage: "calendar.badge.minus")
                            }
                            ForEach(day.admissions) { admission in
                                let key = ProposalDiff.key(date: day.date, admission: admission.admission)
                                AdmissionRow(admission: admission, badge: added.contains(key) ? "New" : nil)
                            }
                            // Keyed by date and time: a removed recurring time repeats across days (0.6.1).
                            ForEach((removed[day.date] ?? []).map { "\(day.date)T\($0)" }, id: \.self) { slot in
                                Label("\(slot.suffix(5)) removed", systemImage: "minus.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let report = self.recentReport {
                    Section {
                        Label(report.headline, systemImage: ReportSection.symbol(report.kind))
                            .accessibilityLabel("Result: \(report.headline)")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(self.model.proposal == nil ? "Done" : "Cancel") {
                    self.model.discardProposal()
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if self.model.proposal != nil {
                    Button("Save…") { self.model.saveProposal() }
                        .disabled(!self.model.controlsAvailable)
                        .accessibilityHint("Asks for confirmation, then saves the proposed schedule")
                }
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)
    }

    /// The result of a save made while the sheet is open.
    private var recentReport: OperationReport? {
        guard let report = self.model.report, let at = self.model.reportAt, at >= self.openedAt else { return nil }
        return report
    }

    private func dayTitle(_ day: ProjectedDay, today: String) -> String {
        let relative = FriendlyTime.day(day.date, today: today)
        let full = FriendlyTime.day(day.date, today: nil)
        return relative == full ? full : "\(relative), \(full)"
    }
}

/// Dates for new time off; an ObservableObject because the app avoids the @State macro here.
@MainActor
final class VacationInput: ObservableObject {
    @Published var start = Date().addingTimeInterval(86_400)
    @Published var end = Date().addingTimeInterval(2 * 86_400)
}

/// Increment B: time off (B1) and one undo of the latest time edit (B3).
private struct VacationSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var input: VacationInput

    var body: some View {
        Section("Time off") {
            if self.model.supports("schedule_vacations") {
                let ranges = self.model.status?.schedule.vacations ?? []
                let today = self.model.projection?.localDate
                if ranges.isEmpty { Text("No time off saved.").font(.callout) }
                ForEach(ranges, id: \.self) { range in
                    let started = today.map { range.start <= $0 } ?? false
                    HStack {
                        Label(VacationText.range(start: range.start, end: range.end), systemImage: "airplane")
                        Spacer()
                        Button(started ? "End After Today…" : "Remove…") {
                            self.model.setting(.include(start: range.start, end: range.end))
                        }
                        .modifier(ActionGate(model: self.model, help: "Scheduled warm-ups return for the days after today"))
                    }
                }
                // Shown in the engine's zone, the same calendar the command is encoded in.
                let zone = self.model.status.flatMap { TimeZone(identifier: $0.schedule.zone) } ?? .current
                let tomorrow = self.tomorrow(zone: zone)
                DatePicker("From", selection: self.$input.start, in: tomorrow..., displayedComponents: .date)
                    .environment(\.timeZone, zone)
                DatePicker("To", selection: self.$input.end, in: max(self.input.start, tomorrow)..., displayedComponents: .date)
                    .environment(\.timeZone, zone)
                Button("Add Time Off…") { self.model.addVacation(from: self.input.start, to: self.input.end) }
                    .modifier(ActionGate(model: self.model, help: "No scheduled warm-ups on these days, both included"))
                Text("Time off starts tomorrow at the earliest. To stop today's warm-ups, pause scheduling.")
                    .font(.callout)
            }
            if self.model.supports("schedule_undo"), self.model.status?.undoAvailable == true {
                Button("Undo Last Time Change…") { self.model.setting(.undo) }
                    .modifier(ActionGate(model: self.model, help: "Restores the schedule before your last time change"))
            }
        }
        .onAppear {
            // The defaults were set at launch; after days of running they could be today or earlier.
            let tomorrow = self.tomorrow(zone: self.model.status.flatMap { TimeZone(identifier: $0.schedule.zone) } ?? .current)
            if self.input.start < tomorrow { self.input.start = tomorrow }
            if self.input.end < self.input.start { self.input.end = self.input.start }
        }
    }

    private func tomorrow(zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    }
}

/// Form input for the editor. A plain ObservableObject (no SwiftUI macros), so the app builds
/// with the Command Line Tools alone. Display state only; nothing here reaches the engine unsaved.
final class EditorInput: ObservableObject {
    enum Scope: String, CaseIterable { case today = "Today only", recurring = "Every day" }
    enum Change: String, CaseIterable { case add = "Add", move = "Move", remove = "Remove", weekdays = "Days" }

    @Published var scope: Scope = .recurring
    @Published var change: Change = .add
    /// An existing time, chosen from the schedule (Move and Remove).
    @Published var current = ""
    /// A new time from the time picker (Add and Move).
    /// Anchored in UTC on a fixed day: only the hour and minute are used, and UTC has no
    /// clock change that could make a valid time such as 02:30 unrepresentable.
    @Published var newTime = ClockTime.date(from: "09:00", zone: ClockTime.utc, now: Date(timeIntervalSince1970: 0)) ?? Date()
    @Published var days: Set<Int> = Set(1...7)
}

private struct ScheduleEditor: View {
    typealias Scope = EditorInput.Scope
    typealias Change = EditorInput.Change

    @EnvironmentObject private var model: AppModel
    @ObservedObject var input: EditorInput

    private var change: Change { self.input.change }

    /// Today-only edits work on today's times (which may include a today-only addition);
    /// recurring edits work on the recurring times.
    private var times: [String] {
        if self.input.scope == .today, let projection = self.model.projection,
            let today = projection.days.first(where: { $0.date == projection.localDate })
        {
            return Array(Set(today.admissions.map(\.logicalTime))).sorted()
        }
        return self.model.status?.schedule.times ?? []
    }

    var body: some View {
        Picker("Change", selection: self.$input.change) { ForEach(Change.allCases, id: \.self) { Text($0.rawValue) } }
            .pickerStyle(.segmented)
        if self.change == .weekdays {
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Toggle(Wording.weekday(day), isOn: Binding(
                        get: { self.input.days.contains(day) },
                        set: { on in if on { self.input.days.insert(day) } else { self.input.days.remove(day) } }))
                        .toggleStyle(.button)
                        .accessibilityLabel(Wording.weekdayName(day))
                }
            }
            Text("Day changes start tomorrow. Today keeps its current times.").font(.callout)
            if self.input.days.isEmpty { Label("Choose at least one day.", systemImage: "info.circle").font(.callout) }
        } else {
            Picker("Applies to", selection: self.$input.scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) } }
                .onChange(of: self.input.scope) {
                    if !self.times.contains(self.input.current) { self.input.current = "" }
                }
            if self.change != .add {
                Picker("Time", selection: self.$input.current) {
                    Text("Choose…").tag("")
                    ForEach(self.times, id: \.self) { Text($0).tag($0) }
                }
            }
            if self.change != .remove {
                DatePicker(self.change == .move ? "New time" : "Time", selection: self.$input.newTime, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, ClockTime.utc)
                    .environment(\.locale, Locale(identifier: "en_GB"))  // 24-hour, like the schedule
            }
            Text(self.input.scope == .today ? "Changes only today's times that have not run yet." : "Starts tomorrow.")
                .font(.callout)
        }
        HStack {
            Button("Preview") { if let edit = self.edit { Task { await self.model.preview(edit) } } }
                .disabled(self.edit == nil || self.model.mutating || !self.model.isBound)
                .accessibilityHint("Shows the schedule this change would produce. Nothing is saved.")
            if let issue = self.model.proposalIssue { Label(issue, systemImage: "exclamationmark.triangle") }
        }
    }

    /// The edit in the engine's argument shape, or nil while the input is incomplete. The engine
    /// validates it again in preview and once more under its lock on save.
    private var edit: ScheduleEdit? {
        let today = self.input.scope == .today
        let picked = ClockTime.string(from: self.input.newTime, zone: ClockTime.utc)
        let current = self.input.current
        switch self.change {
        case .add: return .add(time: picked, today: today)
        // The chosen time must belong to the active scope: switching scope can leave an old choice.
        case .remove: return self.times.contains(current) ? .remove(time: current, today: today) : nil
        case .move: return self.times.contains(current) && current != picked ? .move(from: current, to: picked, today: today) : nil
        case .weekdays: return self.input.days.isEmpty ? nil : .weekdays(self.input.days.sorted())
        }
    }
}

private struct AdmissionRow: View {
    let admission: ProjectedAdmission
    var badge: String?
    /// Today's rows use the Schedule row words (X6) in place of the engine state.
    var words: String?

    var body: some View {
        HStack {
            Text(self.admission.admission).monospacedDigit()
            if self.admission.admission != self.admission.logicalTime {
                Text("moved from \(self.admission.logicalTime)").foregroundStyle(.secondary)
            }
            if let repeated = self.admission.repeatedLocalTime {
                Text(repeated == 1 ? "first (clocks go back)" : "second (clocks go back)").foregroundStyle(.secondary)
            }
            Spacer()
            if let badge = self.badge { Label(badge, systemImage: "plus.circle").foregroundStyle(.tint) }
            if self.admission.next == true, self.words == nil {
                Label("Next", systemImage: "arrow.right.circle").labelStyle(.titleAndIcon)
            }
            // The state is the row's content, so it keeps full contrast.
            Text(self.words ?? Wording.admission(state: self.admission.state, cause: self.admission.cause))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SlotDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let result = self.model.explanation {
                let e = result.explanation
                let today = FriendlyTime.today(zone: result.zone)
                Form {
                    Section(FriendlyTime.slot(e.slot, today: today)) {
                        Label(Wording.verdict(e.verdict), systemImage: Wording.verdictSymbol(e.verdict)).font(.headline)
                        // A detail still read as running is reloaded once the batch ends (AppModel).
                        if e.verdict != "in_progress", let note = self.model.batchNote(for: e.slot) {
                            Label(note, systemImage: "exclamationmark.triangle").font(.callout)
                        }
                        if let admission = e.admission, admission != e.logicalTime {
                            LabeledContent("Ran at", value: admission)
                        }
                        if let missed = e.notAdmitted {
                            LabeledContent("Reason", value: Wording.reason(missed.cause))
                            Text(Wording.guidance(missed.guidance)).font(.callout)
                            if let sleep = self.model.sleepNote(for: e, zone: result.zone) {
                                Label(sleep, systemImage: "moon.zzz").font(.callout)
                            }
                        }
                        if let observed = e.heartbeat.observedAfterAdmission {
                            LabeledContent("Background job checked in afterwards", value: observed ? "yes" : "no")
                        }
                    }
                    ForEach(Array(e.accounts.enumerated()), id: \.offset) { index, account in
                        // Labels on screen (nicknames unless hidden); the copied summary keeps ordinals only.
                        Section(self.model.labels[account.enrollmentId] ?? "Account \(index + 1)") {
                            LabeledContent("Request", value: Wording.dispatch(account.dispatch))
                            LabeledContent("Response", value: Wording.response(account.response))
                            if let reason = account.reason { LabeledContent("Reason", value: Wording.reason(reason)) }
                            Text(Wording.guidance(account.guidance)).font(.callout)
                        }
                    }
                    Section {
                        HStack {
                            Button("Copy Summary") { self.model.copyDiagnostic() }
                                .help("No account names or IDs")
                                .accessibilityHint("Copies reason codes and times only. No account names or IDs.")
                            if let copied = self.model.copyConfirmation, copied.hasPrefix("Warm-up summary") {
                                Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else if self.model.bindingIssue != nil || !self.model.isBound {
                // No usable connection (none, or the engine changed while running): say why, not a
                // spinner or a generic read error.
                EmptyStateView(state: .detailsUnavailable(self.model.bindingIssue))
            } else if let issue = self.model.explanationIssue {
                Label(issue, systemImage: "exclamationmark.triangle").padding()
            } else if self.model.selectedSlot != nil {
                // A time is selected and its details are still being read.
                ProgressView("Loading details…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(state: .noSlotSelected)
            }
        }
    }
}

extension AppModel {
    /// The on-screen name for an Accounts row: its label (nickname or "Account N"), else the Router
    /// account while names are shown, else "Not enrolled".
    fileprivate func accountLabel(_ row: AccountRow) -> String {
        if let enrollment = row.enrollmentId, let label = self.labels[enrollment] { return label }
        return self.hideAccountNames ? "Not enrolled" : row.routerAccountId
    }
}

struct AccountsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?
    @State private var renaming: AccountRow?

    var body: some View {
        VStack(alignment: .leading) {
            if let issue = self.model.accountsIssue { Label(issue, systemImage: "exclamationmark.triangle").padding(.horizontal) }
            if self.model.accountsStale, let good = self.model.accountsReadAt {
                StaleBanner(since: self.model.friendly(good)).padding(.horizontal)
            }
            if let reason = self.model.controlsUnavailableReason, self.model.accounts != nil, !self.model.mutating {
                Label("Actions unavailable: \(reason)", systemImage: "info.circle").font(.callout).padding(.horizontal)
            }
            let zone = self.model.status?.schedule.zone ?? TimeZone.current.identifier
            Table(self.model.accounts?.rows ?? [], selection: self.$selection) {
                TableColumn("Account") { row in AccountNameCell(model: self.model, row: row) }
                    // Room for "Ready · Account 2"; longer states truncate first (0.6.4). The ideal widths
                    // add up to fit the default window with the actions column whole (0.6.5).
                    .width(min: 160, ideal: 200)
                TableColumn("Last warm-up") { row in
                    let text = AccountText.last(row, zone: zone)
                    Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(text)
                }
                .width(min: 120, ideal: 160)
                TableColumn("5-hour window") { row in UsageCellView(model: self.model, row: row) }
                    .width(min: 150, ideal: 180)
                TableColumn("Scheduled") { row in
                    if let enrollment = row.enrollmentId, row.enabled, self.model.supports("scheduled_accounts") {
                        ScheduledToggle(
                            model: self.model, enrollment: enrollment,
                            label: self.model.accountLabel(row))
                    } else {
                        Text("—").accessibilityLabel("Not applicable")
                    }
                }
                .width(min: 70, ideal: 76)
                TableColumn("") { row in
                    AccountActions(model: self.model, row: row) { self.renaming = row }
                }
                .width(min: 36, ideal: 40)
            }
            .accessibilityLabel("Accounts")
            .overlay {
                if (self.model.accounts?.rows ?? []).isEmpty {
                    EmptyStateView(
                        state: .accounts(
                            isBound: self.model.isBound, loaded: self.model.accounts != nil,
                            failed: self.model.accountsIssue != nil))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let id = self.selection, let row = self.model.accounts?.rows.first(where: { $0.id == id }) {
                    let usage = self.model.usageLine(enrollmentId: row.enrollmentId) ?? self.model.usageMissingLabel
                    Label("Usage at last send: \(usage)", systemImage: "gauge.with.dots.needle.50percent").font(.callout)
                    if let cap = row.enrollmentId.flatMap({ self.model.status?.caps?[$0] }) {
                        Label("Daily limit: \(cap) scheduled warm-up\(cap == 1 ? "" : "s")", systemImage: "number.circle").font(.callout)
                    }
                }
                if let notice = self.model.overlapNotice {
                    Label(notice, systemImage: "clock.arrow.circlepath").font(.callout)
                }
                if let report = self.model.report {
                    HStack {
                        Label(report.headline, systemImage: ReportSection.symbol(report.kind))
                            .accessibilityLabel("Result: \(report.headline)")
                        if report.overlap != nil {
                            Button("Run Anyway…") { Task { await self.model.runAnyway(report) } }
                                .disabled(!self.model.controlsAvailable)
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom])
            // Announced once by the Overview pane, which stays loaded in the window.
        }
        .sheet(item: self.$renaming) { row in RenameSheet(model: self.model, row: row) }
        // Hiding names closes an open Rename sheet, whose field shows the nickname.
        .onChange(of: self.model.hideAccountNames) { _, hidden in if hidden { self.renaming = nil } }
    }

}

/// "**Work** · Ready": the bold label, then the state in words with its symbol.
private struct AccountNameCell: View {
    @ObservedObject var model: AppModel
    let row: AccountRow

    var body: some View {
        let label = self.model.accountLabel(self.row)
        let look = AccountText.needsLook(self.row)
        // Two lines, so the state is never cut off at the default width (0.6.3).
        VStack(alignment: .leading, spacing: 2) {
            Text(label).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).help(label)
            HStack(spacing: 4) {
                // Orange on the symbol only; the words keep text contrast.
                Label(AccountText.readiness(self.row), systemImage: AccountText.symbol(self.row))
                    .lineLimit(1)
                    .labelStyle(LegendLabelStyle(tint: look ? .orange : .secondary))
                    .foregroundStyle(look ? Color.primary : Color.secondary)
                // A nicknamed account also shows its number, which run results use (0.6.4).
                if let number = AccountNaming.numberBeside(
                    label: label, number: self.row.enrollmentId.flatMap { self.model.accountNumbers[$0] })
                {
                    // Kept whole at narrow widths; the state truncates first (its text is in VoiceOver).
                    Text("· \(number)").foregroundStyle(.secondary).lineLimit(1).fixedSize().layoutPriority(1)
                }
            }
            .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The short window as the provider reported it at the last warm-up (F2): a bar of the used part,
/// neutral once the reset has passed, the words, and the weekly window as a caption.
private struct UsageCellView: View {
    @ObservedObject var model: AppModel
    let row: AccountRow

    var body: some View {
        if let enrollment = self.row.enrollmentId, let status = self.model.status,
            let account = status.accounts.first(where: { $0.enrollmentId == enrollment })
        {
            // Re-evaluated every minute, so "% left" turns into "Ended" once the reset passes.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = Int(context.date.timeIntervalSince1970 * 1000)
                self.cell(UsageText.cell(usage: account.usage, now: now, zone: status.schedule.zone))
            }
        } else {
            Text("—").accessibilityLabel("No usage")
        }
    }

    private func cell(_ cell: UsageCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if cell.fraction != nil || cell.ended {
                ProgressView(value: cell.fraction ?? 0)
                    .controlSize(.small)
                    .tint(cell.ended ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(cell.main).lineLimit(1).help(cell.main)
            if let weekly = cell.weekly { Text(weekly).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Dims an action while controls are unavailable and says why in its tooltip.
private struct ActionGate: ViewModifier {
    @ObservedObject var model: AppModel
    let help: String

    func body(content: Content) -> some View {
        content.disabled(!self.model.controlsAvailable).help(self.model.controlsUnavailableReason ?? self.help)
    }
}

/// Whether scheduled warm-ups include this account (Increment B2), as a checkbox. A change applies
/// at once (0.5 tiers) and sends the value clicked, not a flip. Table cells get the model passed in:
/// macOS `Table` cells do not inherit environment objects (0.4 crashed opening Accounts).
private struct ScheduledToggle: View {
    @ObservedObject var model: AppModel
    let enrollment: String
    let label: String

    var body: some View {
        let on = self.model.isScheduled(self.enrollment)
        Toggle("Scheduled", isOn: Binding(get: { on }, set: { self.model.setScheduled(self.enrollment, to: $0, account: self.label) }))
            .labelsHidden()
            .modifier(ActionGate(model: self.model, help: on ? "Scheduled warm-ups include this account" : "Scheduled warm-ups leave this account out"))
            .accessibilityLabel("Scheduled warm-ups for \(self.label)")
    }
}

/// The row's actions: rename (local, always available for an enrolled account), and the engine
/// actions warm up, enroll and the daily limit (Increment B4), each confirmed first.
private struct AccountActions: View {
    @ObservedObject var model: AppModel
    let row: AccountRow
    let rename: () -> Void

    var body: some View {
        let enrolled = self.row.enrollmentId != nil && self.row.enabled
        let canEnroll = self.row.enrollmentState == "not_enrolled" && self.row.eligible
        let label = self.model.accountLabel(self.row)
        let gated = !self.model.controlsAvailable
        if enrolled || canEnroll || self.row.enrollmentId != nil {
            Menu {
                if self.row.enrollmentId != nil {
                    // The field would show the saved nickname, which Hide account names keeps off screen.
                    Button("Rename…", action: self.rename).accessibilityLabel("Rename \(label)")
                        .disabled(self.model.hideAccountNames)
                }
                if let enrollment = self.row.enrollmentId, enrolled {
                    Button("Warm Up…") {
                        self.model.request(.runAccount(enrollmentId: enrollment, allowSlotOverlap: false), account: label)
                    }
                    .disabled(gated)
                    if self.model.supports("daily_caps") {
                        let cap = self.model.status?.caps?[enrollment]
                        Menu("Daily Limit: \(cap.map { "\($0) a day" } ?? "none")") {
                            ForEach([1, 2, 3, 4, 6], id: \.self) { count in
                                Button("\(count) a day") { self.cap(enrollment, count) }
                            }
                            Button("No limit") { self.cap(enrollment, nil) }
                        }
                        .disabled(gated)
                    }
                }
                if canEnroll {
                    Button("Enroll…") {
                        // The Router account is named only while names are shown.
                        let shown = self.model.hideAccountNames ? nil : self.row.routerAccountId
                        self.model.request(.enroll(routerAccountId: self.row.routerAccountId), account: shown)
                    }
                        .disabled(gated)
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            // A compact row menu, so the column fits beside the others at the default width (0.6.3).
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(self.model.controlsUnavailableReason.map { "Rename only: \($0)" } ?? "Actions. Each engine action asks for confirmation first")
            .accessibilityLabel("Actions for \(label)")
        } else {
            Text("—").accessibilityLabel("No action available")
        }
    }

    private func cap(_ enrollment: String, _ count: Int?) {
        self.model.setting(.cap(enrollmentId: enrollment, count: count), account: self.model.accountLabel(self.row))
    }
}

/// A nickname for one account (F3), saved on this Mac only. The engine ID shows only while names
/// are not hidden.
private struct RenameSheet: View {
    @ObservedObject var model: AppModel
    let row: AccountRow
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, row: AccountRow) {
        self.model = model
        self.row = row
        self._name = State(initialValue: row.enrollmentId.flatMap { model.accountNames.nickname(for: $0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(self.model.accountLabel(self.row))").font(.headline)
            TextField("Name", text: self.$name, prompt: Text("Work"))
                .onSubmit { self.save() }
            if !self.model.hideAccountNames {
                Text(self.row.routerAccountId).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Saved on this Mac only and never copied. Leave it empty to remove the name.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let issue = self.model.saveIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { self.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { self.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        guard let enrollment = self.row.enrollmentId else { return }
        if AccountNames.clean(self.name) == (self.model.accountNames.nickname(for: enrollment) ?? "") {
            self.dismiss()
            return
        }
        self.model.rename(account: enrollment, to: self.name)
        if self.model.saveIssue == nil { self.dismiss() }
    }
}

/// A pane with nothing to show, in the system's empty-state layout.
private struct EmptyStateView: View {
    let state: EmptyState

    var body: some View {
        ContentUnavailableView {
            Label(self.state.title, systemImage: self.state.symbol)
        } description: {
            if let description = self.state.description { Text(description) }
        }
    }
}

/// First run or a refused binding: what is wrong and the one-time step, at the top of Overview.
private struct SetupStateView: View {
    @EnvironmentObject private var model: AppModel
    let state: EmptyState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(self.state.title, systemImage: self.state.symbol).font(.headline)
            if let description = self.state.description {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let command = self.state.command {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Command") { self.model.copyText(command, confirmation: "Setup command copied") }
                        .accessibilityHint("Copies only the Terminal command. Nothing runs until you paste it.")
                    if let copied = self.model.copyConfirmation, copied.hasPrefix("Setup") {
                        Label(copied, systemImage: "doc.on.clipboard").font(.callout)
                    }
                }
            }
        }
    }
}
