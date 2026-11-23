# Warm-up menu-bar app (Version 2: operator actions, opt-in alerts, the 0.3 evidence views, Increment B controls, the 0.4 interface and the 0.5 effect report)

A native macOS menu-bar companion for the existing Warm-up CLI. The CLI and its LaunchAgent remain the only scheduler, the only owner of operational state and the only request path. The app shows what the engine reports and never writes engine state.

**Status, 20 November 2026 (U4):** installed at `~/Applications/Warm-up.app` and bound to the installed engine. Launched and inspected on the host, macOS 27.3 in dark mode. One supervised manual warm-up of one account was sent from the app; the engine history confirmed it. Three defects found on the host were fixed: the Schedule pane rendered off-screen, the Accounts Action column was clipped, and a misleading "Setup required" label showed before the first read. Not yet checked: VoiceOver, light mode, larger text, pause/resume from the app, and removal.

## What it shows

- **Menu:** one verdict line ("All good · next 13:00 · in 2 h 15 min", with the zone only when it is not the Mac's), or an explicit Needs a look, Paused, Blocked, Held, Background job not running, Running, No warm-up, Unavailable or Setup-required state. Each state has its own symbol and words. The last slot ("08:00 today: all 3 confirmed") opens its explanation; one attention line appears only when there is one.
- **Status:** scheduling, job, Router compatibility, zone mode, last heartbeat, account counts and possible sends without a recorded outcome.
- **Stale heartbeat:** while scheduling is enabled and the job is loaded, a last tick more than 2 minutes older than the engine's own observation time replaces the next-slot headline with "No check-in since HH:MM" ("since 21:00 yesterday" when it is from an earlier day). The next slot moves to the notes. No cause is stated. A missing tick or unreadable observation time is unknown and is not flagged. Paused, Blocked, Held, Job-not-loaded and Running keep their own states.
- **Schedule:** today plus six days from `schedule inspect`, with weekday exclusions, repeated or nonexistent DST minutes and the next admission. Selecting a slot runs `schedule inspect --slot`. The detail separates whether a request was sent, whether a response was confirmed and the guidance. It always shows "Usage window effect unverified". **Copy redacted summary** copies reason codes and times only: no installation ID, account IDs or tokens.
- **Accounts:** rows from `list`, which reads Router's registry without credentials or network.

## Version 0.6.3 (23 November 2026): sidebar, Settings window, Accounts layout, CLI agrees with the app

- **Sidebar:** the main window picks Overview, Schedule or Accounts from a sidebar (Cmd-1 to Cmd-3) instead of toolbar tabs. The window subtitle names the pane. The panes stay loaded, so switching keeps each pane's state. The window opens at 960×640 the first time, under a new saved-frame name.
- **Settings window:** Settings has its own window (Cmd-comma, or Settings… in the menu), as macOS apps usually do; it never merges into the main window as a tab. Refreshes run while either window is visible. A missed slot counts as seen only while the main window is key with Schedule showing and no sheet open.
- **Accounts:** the account's state sits on a second line under its name, and the row actions are a compact "…" menu, so nothing is cut off at the default width.
- **CLI:** `--status` and `--json` read the app's "problem seen" value (`acknowledgedProblemSlot`, read-only). After you open a missed slot in Schedule, the CLI stops saying "Needs a look" for it and exits 0, like the menu.
- **Privacy and wording:** confirmations name an account only by its on-screen name. With Hide account names on they say "this account", never a Router or enrollment ID. Warm-up results name the account each result is about, not its position in the engine's reply.

## Version 0.6.2 (23 November 2026): macOS 26/27 UI pass on top of 0.6.1

- Warning words (account readiness, Health) keep text contrast; orange stays on the symbol only (orange text is about 2.2:1 on light backgrounds).
- Overview leads with whatever blocks everything: the reconnect card, or a first-run "Connect Warm-up to the engine" card that names the one-time provisioning step.
- System empty states (`ContentUnavailableView`) for Schedule details and Accounts; the words live in Core (`EmptyState`).
- The hero state symbol morphs when the state changes and pulses while a change runs (both follow Reduce Motion).
- Leading SF Symbols on the status menu's actions (Warm Up, Pause/Resume, Open, Settings, Quit), from Core (`MenuIcons`).
- The Accounts usage cell re-reads the clock every minute, so "% left" becomes "Ended" after the reset.
- The quit-while-changing dialog comes to the front; the first toolbar tab no longer keeps its focus ring on every tab.
- Larger text for meaning-bearing captions (week legend, weekly usage, rename hints).
- No glass is added to content: system controls, toolbar and menus already take Liquid Glass on macOS 26 and later.

## Version 0.6.0 (measurement and visibility)

Nothing new is sent to the engine. Every change below reads what the engine already reports, or keeps a small private file on this Mac.

- **Did it help? decision.** Settings has a "count from" date. From that day, Overview shows progress ("3 of 10 warm-ups measured since 1 Dec") and, once 10 warm-ups have a clear answer, a decision: keep the schedule, turn it off, or keep measuring. "Turn the schedule off" offers Pause Scheduling…, which asks for confirmation as usual. Details list every measured warm-up with its time, account, effect and when its window reset. Without a date, one line says to set one.
- **Usage at a glance.** The menu lists up to four accounts with what the provider reported at the last warm-up ("96% left · resets 13:02"). Accounts has a 5-hour window column with a bar of the used part (grey once the window has reset) and the weekly window under it.
- **Account names.** Accounts › Actions › Rename… gives an account a name, shown on screen, in the menu and to VoiceOver only. Settings › Privacy › Hide account names shows "Account 1", "Account 2" instead. Copied text and CLI output always number accounts.
- **Reconnect after an engine update.** When the engine no longer matches its connection, Overview and Settings show the exact Terminal command to reconnect, with Copy Command. The app never reconnects itself.
- **Today.** The menu has a Today line ("✓ 08:00 ○ 13:00 ○ 18:00"); Overview has a cell per time that opens it on Schedule.
- **Needs attention.** Possible sends without a result can be marked as reviewed. They are hidden in the app only; "Show reviewed" lists them again, and the engine's records are unchanged.
- **Schedule.** A summary row with Edit Times…, which opens the editor in a sheet (Preview, then Save… or Cancel). Spacing advice when two times sit inside one usage window. Today's rows say what happened; later days that repeat the usual times fold to one line; "Earlier this week" lists past days. Schedule opens on the time that needs a look, else the latest finished one today, else the next one. The detail's copy button reads Copy Summary and never includes account names or IDs.
- **Menu bar.** "Menu bar shows" picks Icon only, Time left or Next time. The icon dims while the last read failed.
- **Fewer reads.** Each refresh reads only what the visible tab needs; alerts check after each scheduled time and every 15 minutes.
- **Command line.** `WarmupMenu --status` prints the verdict, today's times, health and accounts; `WarmupMenu --json` prints the same facts as JSON. Both read the engine through the stored connection and print no IDs, paths, names or emails. Exit codes: 0 all good, 1 something needs attention, 2 nothing could be read, 64 wrong arguments.
- **New private files** in the app's folder (0600, beside the engine connection): `account-names.json` (names) and `reviewed-sends.json` (the times marked as reviewed). Settings › Privacy › Show in Finder opens the folder.
- **0.6.1:** Schedule's Earlier this week showed one day's results on another.
- **Not in 0.6.0:** the Results tab, "Best right now" (F13), and Developer ID signing; the app is still signed ad hoc.

## Version 0.5.1 (22 November 2026)

Fixes only, from the second review (FABLE-PLAN-2).

- **Did it help?** A send that lands with 10 minutes or less left in a running window is now its own class, "landed just before the old window reset". Like *unclear*, it never counts toward the verdict, so the 08:00/13:00 spacing can no longer tip it by a few seconds of jitter.
- **Dates on any Mac.** Every fixed date and time string uses POSIX digits and the Gregorian calendar, so "today", time off and the wake command work on a Mac set to another numbering system or calendar.
- **Schedule read errors stay on Schedule.** A failed schedule read shows there only; it no longer dims every action or hides the countdown.
- **Cut lists say so.** When the engine lists only the newest possible sends, the count reads "50 or more".
- **Setup card.** It goes away once each switch has been changed (here or in Settings) or Done is pressed.
- **Quieter Overview.** Possible sends without a result appear in Needs attention and the menu, not again in the headline card.
- **Plain words.** The weekly headline reads "2 of 6 scheduled warm-ups confirmed · 15–21 Nov"; missed times give their reason in words; VoiceOver reads days as "Monday 16 November". Leftover engine words (slot, tick, admission, pilot, vacation, cap, engine lock) and ISO dates are gone from what the app shows. Copied diagnostics keep their codes.
- **Accounts.** A check mark only for Ready; a minus for Turned off and a plus for Not added yet. The last-result column is wider and wraps.
- **Window and Settings.** The window is always titled "Warm-up". Settings shows "Warm-up 0.5.1 (6) · Engine 1.2.0". Section footers are leading-aligned.
- **Accessibility.** Results, check-in problems and alert issues are announced whichever tab is loaded. Explain buttons name what they explain, week marks are at least 28 points square, and Dismiss sits in the result row, not the heading.
- **Fewer wake-ups.** The menu-bar countdown timer runs only while the countdown is on; the window's refresh timer has a 5-second tolerance.
- **Provisioning** prints "Bound." and the binding file path, never the installation ID.
- **After review (Codex, three rounds).** Copied weekly reports keep full dates and cause codes. Possible sends without a result have their own menu line. A busy schedule read keeps the last good schedule. The setup card stays until a change has actually taken effect, and shows why one failed. A second missed time is announced too. Time-off confirmations name the year. A copied status summary says when the list of possible sends was cut.

## Version 0.5 (21 November 2026)

- **Did it help? (Overview).** Every time the app reads status it keeps the latest usage observation per account when it is new (the short window's length, reset time and used percent seen at a send) in `usage-log.json`, a 0600 file in the app's private folder, for 60 days (pruned on every read) and at most 1,000 rows. Status reports only the latest send per account, so sends between two reads, or while the app was closed, can be missed or picked up late. The section classifies each send of the last 14 days: *started a fresh window* (the reset is one window length after the send, within 10 minutes), *inside a running window* (the reset comes sooner), *no short window* (none under a day was reported) or *unclear*. Unclear sends never count: the verdict needs at least 10 sends with a clear answer and a strict majority either way, and otherwise says "No clear answer". The verdict never invokes the stop rule itself, because the rule is for data after the December change. It covers sends seen while the app was running and is an observation of the provider's headers, not proof of cause. Copy Effect Report copies counts with accounts numbered. Stop rule: if, after OpenAI's December allowance change, most warm-ups start no fresh window, turn the schedule off and keep only manual warm-ups.
- **Two confirmation tiers.** A dialog (Cancel is the default) for anything that sends, enrolls, pauses, resumes or changes times, including Undo. Time off, scheduled accounts and daily caps send nothing and are undone with the same control, so they apply at once; each still carries the revision and local-date guards and reports its result. The Scheduled checkbox sends the value clicked (never a flip of an older read), and when every enrollment is enabled, re-adding the last one an explicit list left out returns to "all enabled accounts" (with a disabled enrollment it stays an explicit list, so later enrollments are not scheduled until added).
- **Needs attention, grouped.** Possible sends without a recorded result are grouped per time (with an account count and Explain) plus one row for manual warm-ups; more than three groups fold under "Show N times".

## Version 0.4 interface (21 November 2026)

A UI/UX pass from Fable 5.2's review (`../../FABLE-PLAN.md`, items I1–I24). Logic is in WarmupCore with tests (`Friendly.swift`, `Health.swift`, `UXTests.swift`); WarmupMenu stays a thin shell.

- **The icon is right without a click.** The app reads status (read-only) at launch, after each wake, two minutes after each slot and otherwise every 15 minutes (`RefreshPlan`). The latest slot with a problem you have not opened shows as "Needs a look: 08:00 today" with its own symbol until you open its explanation.
- **Plain words.** Engine codes go through one table (`Wording.reason`): "missed (nothing ran at that minute)", "daily limit reached", "needs a first manual warm-up". Times read "Today 12:31", "Yesterday 18:00", "Mon 16 Nov 08:00"; time off reads "1–5 Dec (5 days)". Notifications say "The 13:00 warm-up was missed" (macOS already shows the app name).
- **Four tabs.** Overview, Schedule, Accounts and Settings (Cmd-1 to Cmd-4, Cmd-comma for Settings). The menu has Open Warm-up and Settings…; it opens the window only when an action was confirmed, and says "Warming Up…" while one runs.
- **Overview:** the verdict, countdown and last slot with Explain; Warm Up Now… and Pause/Resume; the check time and Refresh, all in the first card. Below it: the last result with its time and Dismiss; a one-time "Finish setting up" card for alerts and login; Needs attention (possible sends without an outcome, never resent) only when there is one; Last 7 days (sentence, clickable marks, Details with Copy Weekly Report); Health, collapsed to "All checks pass" when every check passes. A failed read shows "Showing the last successful read, Today 12:31". Buttons no longer dim during background reads; a confirmed action is reserved at once (a second confirmation cannot queue behind it) and waits for a running read to finish.
- **Schedule:** a summary row, then the days ("Today, Mon 23 Nov · 3 warm-ups"), selectable by keyboard; Edit times in a disclosure, with a list of current times and a 24-hour time picker; the proposal states the change ("Adds 21:05 every day, from tomorrow.") and marks new and removed rows. Time off with "End After Today…" for a started range; Undo appears only while it is available. The slot detail has a symbol per verdict and plain rows, and names each account (the copied summary keeps numbers only).
- **Accounts:** four columns: the account with one readiness phrase, Last warm-up, a Scheduled checkbox, and an Actions menu (Warm Up…, Enroll…, Daily Limit). Usage and the daily limit show for the selected account. Run Anyway… is offered here too after an overlap refusal.
- **Settings:** General (open at login, menu-bar countdown), Alerts, Advanced (engine connection, Copy Status Summary, and how to wake the Mac; `pmset` keeps one repeating wake, so it covers one time a day).
- **Confirmations:** short verbs on the confirm button (Warm Up, Pause, Save, Add, Remove, Set Limit). Results are sentences: "All 3 accounts confirmed.", "Scheduling is paused.", "Not done: that time has already passed today."

## Version 0.2 interface (21 November 2026)

- **Status header:** a large state symbol and headline, a live "Next slot in 2 h 15 min" countdown, the last slot with Explain, and the notes in full contrast. A stale heartbeat now has its own symbol (a crossed-out heart) in the menu bar and header, instead of the shared warning triangle.
- **This week:** seven day columns built from read-only `history` (the last eight days), the not-admitted ledger and the latest batch. Each slot shows a symbol, its time and a color: confirmed, outcome uncertain, finished with problems, not admitted, or skipped; manual account results are counted per day (one per account, skipped ones included). Only recorded evidence is shown, so a quiet day stays empty. A batch still running, one newer than the last outcome status reported (or the newest one before any outcome is known), or the oldest batch in a history cut at 50 rows, is never shown as confirmed. VoiceOver reads each day as one sentence.
- **Wake readiness:** reads `/usr/bin/pmset -g sched` (read-only, fixed arguments, 3-second limit) and says whether a wake you scheduled with `pmset` falls within 30 minutes before the next slot, including one the evening before a slot just after midnight. Repeating events are read in every form `pmset` prints (weekdays, weekends, every day, day names or letters). The system's own short maintenance wakes (owners starting `com.apple.`) do not count. When none is scheduled, it offers a copyable `sudo pmset repeat wakeorpoweron MTWRFSU HH:MM:00` command; the app never runs it. `pmset repeat` replaces any repeating schedule already set, and the app says so when one exists.
- **Copy Status Summary:** a redacted text summary of the whole status (codes, counts and local times only; no installation, enrollment, reservation or account identifiers, and no paths). Engine text is copied only in a known shape (a lowercase code, a date or time, a version, or a real time-zone name); identifier-like text, text containing this Mac's user name and anything else is replaced with "(withheld)". The button is off while the engine is shown read-only after a binding mismatch. The slot summary keeps working; both confirm with "copied".
- **Open at login:** an opt-in switch that registers the app with macOS Login Items (`SMAppService`). Off unless you turn it on. A registration waiting for approval in System Settings shows as on, with a note, so it can still be withdrawn; the state is read again whenever the app becomes active.
- **Menu-bar countdown:** an opt-in switch that shows the time to the next slot (for example `2h 15m`) beside the icon, updated every 30 seconds. Off by default. It is hidden after a failed status read, and once the slot is two minutes past, the app reads status again (read-only, at most every five minutes) so the label moves on.
- **App icon:** an original dawn-and-clock icon (`Resources/AppIcon.icns`, drawn by `Scripts/make_icon.swift`; no SF Symbols, whose license excludes app icons).
- **Menu:** the headline and the job note are full-contrast items that open Status, and a countdown line shows the next slot.

## Version 0.3 evidence views (21 November 2026)

Built with engine 1.1.0-offline. Every new view also works against engine 1.0: a field the engine does not send is simply not shown.

- **Engine lock:** the Scheduler section shows who holds the engine's work lock (free, a running engine process, a stopped process, or an owner the app cannot verify). When a stopped process left it, or its owner is unknown, a note names that cause. While the heartbeat is stale the note comes first, so "No heartbeat since 11:19" now says why. Engine 1.1 clears a lock left by a stopped process at a later check when no other recovery is running; the note says that, without promising a time.
- **Usage at last send (Accounts):** for each account, the usage windows the backend reported when the engine last sent a warm-up: for example "5-hour window 42% used, resets 13:30. Weekly window 12% used, resets Sun 09:00. Seen at 08:00." It is an observation at send time, not a live meter, and it is "Not observed" until engine 1.1 has sent one ("Not observed, or left out of a large reply" when the engine had to drop usage from a very large reply).
- **Last 7 days (Status):** a report built from the same evidence as the This week strip. It shows how many scheduled slots were confirmed out of those that counted, plus the uncertain, problem, not-admitted and ran-but-sent-nothing counts (cooldown, pilot or correction needed), the not-admitted causes and the manual results. Only slots skipped by your own pause, a recovery boundary or an empty account selection are left out of the count. The report shows when it was read. A history read cut at its row limit is stated, and so is a not-admitted list that reached its 50-row limit inside the week (older misses may be missing). A failed read clears the report instead of leaving an old one. **Copy Weekly Report** copies it with the date range and read time, and numbers the accounts (Account 1, Account 2) instead of naming them.
- **Sleep journal:** while Warm-up is open it records when it starts and when the Mac sleeps and wakes (macOS workspace notifications). It keeps 14 days in a private file beside a verified engine binding: `sleep-journal.json`, mode 0600, in the 0700 folder. Reads are bounded and never follow a link, writes are atomic, and the file is never sent anywhere. The admission minute comes from the miss's own ledger row (its recorded time and zone), so a later schedule or zone change cannot shift it, and a minute that a clock change made ambiguous or skipped (including 30-minute shifts) gets no note. When that whole minute falls inside one recorded sleep, the slot explanation adds "Warm-up recorded the Mac asleep from 12:41 to 14:02, which covers this admission minute." It states what was recorded, not the cause. It never pairs a sleep with a wake across an app restart, and says nothing about times when Warm-up was not running.
- **Why actions are dimmed:** when Warm Up, Pause, Resume or Enroll are unavailable, the Status and Accounts views say why (for example "The last read failed … Refresh to try again"), and each account button's tooltip gives the reason.
- **Run Anyway, scoped:** with engine 1.1 the override names the exact admission instant from the refusal (`--overlap-at`). The engine then refuses it if another slot became next after you confirmed, if the admission was moved, or if it is the other occurrence of a repeated fall-back minute. The app also withdraws the offer when the instant changed. This closes the race noted for 0.2.

## Increment B controls (app 0.3 with engine 1.2)

Shown only when the engine advertises the feature. Each control sends one guarded engine mutation with the current revision. Since 0.5, Undo asks for confirmation (Cancel is the default); time off, scheduled accounts and caps apply at once.

- **Schedule › Vacations and undo:** the saved vacation ranges, each with Remove…, and From/To date pickers with Add Vacation…. The pickers show dates in the engine's schedule zone, the same calendar the command is sent in. Removing a range takes effect tomorrow: a range that has started keeps its past days and today, and one ending today or earlier cannot be removed. Undo Last Time Change… is enabled only while the engine reports `undoAvailable`.
- **Accounts › Scheduled:** "Yes — Remove…" or "No — Add…" per enabled account. The engine applies the change under its lock to the accounts it holds then (`--add`/`--remove`), so an account enrolled after this window last loaded is never dropped by accident. The first change turns "every enabled account" into an explicit list, so later enrollments stay out of the schedule until you add them. Manual Warm Up still reaches every enabled account.
- **Accounts › Daily cap:** a menu of 1, 2, 3, 4 or 6 scheduled warm-ups a day, or No cap. Manual warm-ups are not capped. A slot skipped only because of a cap is not an alert or a problem in the week strip, and the weekly report leaves it out of the rate. A batch the engine stopped is always an alert, whatever its rows say, including in catch-up from history (engine 1.2 rows carry `batchOutcome`, and `status.blockedSlots` covers a stopped batch with no saved rows; its alert says sends are unknown rather than counting them). Slots that pass while no account is chosen for scheduling are shown as skipped by choice, not missed.

### Accessibility and keyboard

- While the window is open, Warm-up is a regular app with a Dock icon, a place in Cmd-Tab and a main menu: Cmd-W, Cmd-M, Cmd-Q, Hide, the Edit commands (copy and paste in the time fields), Cmd-1/2/3 for the tabs and Cmd-R to refresh. Closing the window returns it to the menu bar only.
- The confirmation dialog brings the app forward first and starts with keyboard focus on Cancel.
- Results, a stale heartbeat, permission problems, copies, previews and loaded slot explanations are announced to VoiceOver, once per event even when the text repeats.
- The selected schedule slot is highlighted and exposed as selected. Weekday buttons are read as full day names; slot state text and notes use full contrast.
- Disabled controls say why (for example "Alerts need a verified engine binding", "Use 24-hour time, for example 09:30"). The Accounts table is labeled and has an empty state.

### Safety changes in 0.2

- **Launch-time binding check (U4 review #1):** before every change, the app checks the bound files again and recomputes the engine build digest from the four engine modules (the same SHA-256 framing the engine reports). The bound script must be `warmup.mjs` itself, and each module must be a regular file (not a link) that only you or root can change, so the hashed bytes are the bytes Node loads. If anything changed since the binding was verified, the change is refused before any process starts.
- **Bounded replies (U4 review #2):** a helper process that inherits the engine's output pipe can no longer hold a read open past its deadline; the read ends as a timeout, and the app cancels its readers and closes its pipe descriptors before it returns, so no reader thread is left behind. The readers are set up before the engine starts; if that fails, the engine is not started.
- **Run Anyway (U4 review #3):** after an overlap refusal, Run Anyway reads status again before the confirmation dialog and again after you confirm, and sends the override only when that second read is fresh and succeeds, the schedule zone is unchanged, and the refused slot (same ID, date and admission time) is still the next slot. Otherwise it says why the override was not sent.
- **Slot detail (review #9):** selecting a slot clears the previous detail and its Copy button at once; only the newest request can fill it.

## Operator actions

Actions that send, enroll, pause, resume or change times ask for confirmation (0.5 tiers, above). In every confirmation dialog, Cancel is the Return default. Each action runs exactly one allowlisted command and shows the engine's reply under **Last result**.

| Action | Where | Engine command | Notes |
|---|---|---|---|
| Warm Up Now | menu, Status | `run` | One request per enabled account. The dialog says each counts toward usage and gives the account count from the last check. |
| Warm Up (one account) | Accounts row | `run --account ENROLLMENT` | The dialog names the Router account. |
| Run Anyway | Last result | `run … --allow-slot-overlap` | Offered only after the engine refused with `slot_overlap_risk`. It needs a new confirmation that says the due slot may be skipped. It is never resent automatically. |
| Enroll | Accounts row | `enroll --account ROUTER_ACCOUNT` | Sends nothing. A manual pilot is still required before scheduling. |
| Pause / Resume Scheduling | menu, Status | `schedule disable|enable --expected-revision N` | Resume shows the enabled and pilot counts from the last check and states that nothing is caught up. |
| Change the schedule | Schedule | Preview: `schedule inspect <edit>`. Save: `schedule <edit> --expected-revision N --expected-local-date D` | Today-only or recurring add, move or remove, or weekdays. Save uses the preview's own revision and date, so a stale preview is refused and needs a fresh preview. The app also drops a preview once the observed revision or date moves. |

Every action also carries `--expected-installation-id`. While one runs, all other actions and the app's own refreshes wait. Nothing is queued or retried.

**Unknown outcomes.** If a change's reply is lost, malformed, oversize, or accepted without its result fields, the app reports **outcome unknown** and refreshes status. It offers no new change until a valid status read has completed that started *after* the unknown outcome. The engine may have acted, so nothing is repeated.

**Quit and relaunch.** Quitting while a change runs never cancels or pauses anything. The app offers Keep Open or Hide Window until the engine replies. The app stores no pending operations, so a relaunch only observes state.

With a verified binding, opening the app runs one read-only `status`, so the menu-bar icon is right without a click; it then reads `status` in the background (two minutes after each time, otherwise every 15 minutes). Opening the menu runs `status` once. The window refreshes on open and every 30 seconds only while visible. No view sends a provider request.

## Problem alerts (A3, opt-in)

**Settings → Alerts** (also offered once in the Overview setup card) has one switch, off by default. Turning it on asks macOS for notification permission. A refusal is reported in the pane, and the app changes no system setting.

- **What counts as a problem:** a recorded not-admitted slot (for example `no_tick_between`, `schedule_spacing`, `zone_changed`, `manual_run_overlap`, `clock_hold` or `compatibility_blocked`), or a finished scheduled batch whose outcome is neither `success` nor `idle` (`idle` means no account was enabled). A pause (`schedule_disabled`) or a recovery boundary is the operator's choice and is not announced. An unobserved minute is not announced until the engine records it.
- **Baseline and deduplication:** problems the engine recorded before alerts started (launch, or switching alerts on) are never announced. Problems recorded later are announced by the first successful read, even if the baseline read was skipped or failed. A different installation is baselined whole. Each installation and logical slot is announced at most once per app run, and several new slots in one read become one notification. Only a verified binding is observed.
- **Permission:** asked only when you switch alerts on; if macOS later forgets the decision, the pane says so and switching alerts off and on asks again. It is checked (never asked) at launch, every 5 minutes and before each notification. If it is revoked, reads and announcements stop and the pane says so; problems that could not be shown are announced once permission returns. A notification that macOS rejects for another reason is reported in the pane and not retried.
- **Reads:** while alerts are on and allowed, the app runs read-only `status` at launch and then every 5 minutes (only while the Mac is awake and the app runs). Menu and window reads feed the same check. Status shows only the latest finished batch, so when it is newer than what earlier reads covered, the app also runs read-only `history` from that point and announces the scheduled batches that finished in between (for example an 08:00 failure followed by a 13:00 success while reads were failing). The read reaches back one batch length, so a batch already running when alerts started is judged on all its rows; only batches that finished after the previous check count. If that `history` read fails, the next read retries from the same point. If the reply was capped (the oldest returned batch may then be cut off, so it is left out) or the gap is older than the engine's 30-day history, a separate notification says some earlier slots could not be checked; it is sent once per gap and kept if it cannot be shown. No warm-up request is sent and nothing is written.
- **Text:** "The 13:00 warm-up was missed", the friendly time, the zone only when it is not the Mac's, reason in plain words, and sent, confirmed and unknown counts only. Engine codes are mapped to fixed wording and never copied into a notification; an unrecognized code gets generic wording, and a malformed slot or zone is left out. No installation, enrollment, reservation or Router identifiers. Silence is never given a cause such as sleep. Clicking a notification opens Schedule at that slot's explanation.

## Engine binding

The app runs commands only through a reviewed binding stored at `~/Library/Application Support/local.warmup.menu/engine-binding.json` (directory 0700, file 0600). The binding holds the Node path, the canonical script path, the engine build digest and the installation ID. It never holds credentials, accounts or schedule state. Without it, the app shows **Setup required** and runs nothing.

The binding is created only by an explicit operator step, with the app not running:

```sh
WarmupMenu --provision-binding --node /opt/homebrew/opt/node@22/bin/node --script /ABSOLUTE/PATH/warmup.mjs --expect-build sha256:<digest from a reviewed status>
```

That step checks file ownership and modes, runs read-only `status` through exactly those paths, and requires capability version 1. The reported build and paths must match before it writes. At every refresh the app compares the installation, capability, build and paths again. Any mismatch keeps every command except `status` unavailable until an explicit rebind. The engine reports its own build digest. The check therefore detects an accidental or unreviewed engine change, but it does not protect against a deliberate replacement by a process running as the same user. The app never searches `PATH` or rebinds automatically.

## Command adapter

`WarmupCore/EngineCommand.swift` is the complete allowlist. Read-only commands are `status`, `list`, `history`, `timing`, `schedule inspect`, `schedule inspect --slot` and `schedule inspect <proposed edit>`. The guarded mutations are the operator actions above, and each one carries `--expected-installation-id`. Schedule mutations also carry `--expected-revision`, and edits add `--expected-local-date`.

- The adapter runs an absolute executable with structured arguments and no shell. The environment is limited to `HOME`, `PATH=/usr/bin:/bin` and `LANG=C`, with no `TZ`, so the engine resolves the Mac's zone itself.
- Stdout is capped at 1 MiB and stderr at 64 KiB, and both are drained concurrently. Stderr is never parsed.
- Each reply must be one JSON object with protocol 1, the expected command and installation, and an exit status that agrees with its outcome (0 ready/idle/success, 1 partial, 2 blocked, 3 busy, 4 no_work).
- Reads time out after 10 seconds. A timeout terminates only that read's own child.
- At most one mutation runs at a time. The app never retries, queues or kills a mutation, and mutations have no app-side timeout. A lost or malformed mutation reply is reported as an unknown outcome, which needs a fresh status read before any new action.
- A command whose engine capability feature is missing fails locally without starting a process.

## Build, test, stage

Requires the Swift 6.2+ toolchain. Verified with Command Line Tools Swift 6.4.2 and SDK 27.2 on arm64 macOS 27.3. The minimum OS is macOS 15, matching the donor manifest. It has not been tested on macOS 15 itself.

```sh
swift build
Scripts/test.sh                       # Swift Testing via `swift test` (Xcode toolchain; see AGENTS.md)
Scripts/package_app.sh /ABSOLUTE/OUT   # stages Warm-up.app, ad-hoc signed, never installed or launched
```

The Swift tests decode `../test/fixtures/ui/*.json`. The Node suite (`test/ui-fixtures.test.mjs`) proves those fixtures equal real engine output for synthetic installations. After an intentional engine contract change, regenerate them with `tools/extract-ui-fixtures.mjs`, as described in that file, and review the diff.

## Install, update and remove

- **Install:** copy the staged `Warm-up.app` to a location you control, run the provisioning step and open the app.
- **Update:** quit the app, replace the bundle, and reprovision only if the engine changed.
- **Remove:** quit the app, delete the bundle and `~/Library/Application Support/local.warmup.menu`.

Removing the app never changes the engine, its schedule or the LaunchAgent.

## Known limits

- Accessibility, light/dark and keyboard behavior use native controls and system colors. Version 0.2 was launched on the host on 21 November 2026 and its Status, Schedule and Accounts tabs were checked by screenshot in light mode; it has not yet been run under VoiceOver or in dark mode. The window and menu logic (AppModel, StatusItemController, AppMain) has no automated tests. The core it calls does.
- Shared state uses `ObservableObject` property wrappers; views use `@State` for local state (the Xcode-beta toolchain ships the macro plugin). Moving to `@Observable` is planned, not done.
- Distribution is local only. The app is ad-hoc signed, with no notarization or updater, so `spctl` rejects it. It runs locally because it has no quarantine attribute; don't download or AirDrop the bundle.
- Closing the window returns Warm-up to a menu-bar-only app; reopen the window from the menu.
- Increment B (vacations, scheduled accounts, one undo and daily caps) needs engine 1.2. Increment C is the Last 7 days report (seven days, from the 50 most recent history rows); a longer report needs a larger engine history read.
- Alerts are armed with the Mac wall-clock time. If the clock is stepped backward after alerts start, problems recorded in that window can be treated as pre-existing and not announced.
- The catch-up `history` read returns at most the 50 most recent rows from the last 30 days. After a longer gap with many batches, the oldest missed batches are not announced individually; the "some earlier slots could not be checked" notification is sent instead.
- A scheduled batch that ends in an engine error (for example `state_capacity`) leaves no `history` row for the accounts it did not reach, so its rows can look clean. It is announced reliably only while it is still the latest batch outcome. Closing this needs the engine to record unprocessed accounts on its error path.
- Problems recovered from `history` are labeled with the current schedule zone, not the zone in which they ran.
- A batch rebuilt from `history` is timed by its last account row, not its finalization. A batch whose last row was saved just before alerts started and that finished just after is treated as pre-existing.
- If the alert outbox file cannot be written, macOS also refuses the notification, and the app then stays closed for more than 7 days, the 7-day relaunch limit can skip that alert. A failing disk is outside what the app can make durable.
- The alert outbox holds 200 owed slots. If more than 200 alerts stay undelivered (notifications refused for weeks), the extra ones are kept only in memory and the app shows "Alerts could not be saved"; quitting and then staying closed for more than 7 days can skip them. Zone labels come from the status the app read when the problem was found, so a slot first seen after a time-zone change carries the new zone.
- Alerts are tested on fixtures only. Notification permission and delivery for this ad-hoc signed bundle have not been checked on the host.
- Run Anyway needs an engine that advertises `scoped_slot_overlap` (engine 1.1), so the override covers only the time the warning named. With an older engine the app sends no override and asks you to wait until the scheduled warm-up has run.
- The launch-time check and the engine launch are separate steps. A process running as you that rewrites the engine between them is outside what the app can prevent; the engine install's own file permissions are the boundary.
- On a daylight-saving fall-back day, an admission time inside the repeated hour occurs twice. Engine 1.1 reports the selected instant (`next.at`) and the countdown and wake check use it; with engine 1.0 they can name the first occurrence while the engine waits for the second.
- The sleep journal only covers time when Warm-up was running, and a Mac that loses power records no sleep. A missed slot without a recorded sleep says nothing about sleep.
- Usage windows are what the backend reported at the last send. They go stale between sends and are not a forecast.
- The status summary's redaction is shape-based. A lowercase word the engine might put in a code field (for example a bare handle) cannot be told apart from a code. Result and preview text announced to VoiceOver is the same text shown on screen; it is not filtered further.
- The wake check compares wall-clock minutes. On a spring-forward night it can reject a wake that is in fact less than 30 minutes before the slot (for example 01:55 before a 03:05 slot when 02:00 jumps to 03:00).
