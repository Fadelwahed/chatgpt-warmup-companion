# Accessibility and appearance check (about 20 minutes, on the host after an install)

Run this after every app release that changes a pane. Write the date, app version and result for each line in the handoff.

## Code pass (done 21 November 2026, app 0.5)

- Colors are system colors (`.green`, `.orange`, `.red`, `.blue`, `.tertiary`), so they adapt to light and dark mode. Every state also has its own symbol, so color is never the only signal.
- Text uses text styles (`.headline`, `.callout`, `.caption`), never fixed point sizes.
- Decorative images are `accessibilityHidden`. Week marks, Explain buttons and Copy buttons have labels or hints.
- Not proven by the code pass: what VoiceOver actually reads, contrast in light mode, and keyboard focus order.

## On the host

1. **Keyboard only.** Turn on Full Keyboard Access (System Settings › Keyboard › Keyboard navigation). Open Warm-up from the menu. The window has a sidebar with three panes: Cmd-1 Overview, Cmd-2 Schedule, Cmd-3 Accounts. Settings is a separate window (Cmd-comma). With Tab, Shift-Tab, the arrow keys and Space, reach every control in the three panes and in the Settings window, including "Show turned-off accounts" under the Accounts table (shown while an account is turned off) and "Set Start Date…" in Settings (shown while no start date is set). From the menu bar, open Schedule › Warm Up Now… and Schedule › Pause Scheduling…. Every confirmation dialog starts on Cancel.
2. **VoiceOver** (Cmd-F5). On Overview, the headline is read first, then the actions. A week mark is read as "13:00 confirmed, button". A result is announced after Warm Up Now and after a copy. On Schedule, the arrow keys move between slots and VoiceOver says "selected". An upcoming time is read with its wake mark ("wake booked" or "no wake") and "today only" where shown. On Overview, the cause line under "Last 7 days" is read as one sentence. On Accounts, the usage cell reads its "Seen …" line.
3. **Light mode.** Switch the Mac to Light. Check that the orange and green marks and the hero symbol are still easy to see on Overview and Schedule.
4. **Larger text.** Set System Settings › Accessibility › Display › Text size to the largest that applies to apps. Check that nothing is clipped in the hero card, the week strip and the Accounts table at the default window size. In 0.7.0 the Accounts usage cell has three lines and Schedule rows carry trailing labels: check both.
5. **Menu bar.** With Reduce transparency and Increase contrast on, the menu-bar symbol is still readable.

Record any failure as a backlog item with a screenshot.
