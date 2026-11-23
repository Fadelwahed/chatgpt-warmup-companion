# Accessibility and appearance check (about 20 minutes, on the host after an install)

Run this after every app release that changes a pane. Write the date, app version and result for each line in the handoff.

## Code pass (done 21 November 2026, app 0.5)

- Colors are system colors (`.green`, `.orange`, `.red`, `.blue`, `.tertiary`), so they adapt to light and dark mode. Every state also has its own symbol, so color is never the only signal.
- Text uses text styles (`.headline`, `.callout`, `.caption`), never fixed point sizes.
- Decorative images are `accessibilityHidden`. Week marks, Explain buttons and Copy buttons have labels or hints.
- Not proven by the code pass: what VoiceOver actually reads, contrast in light mode, and keyboard focus order.

## On the host

1. **Keyboard only.** Turn on Full Keyboard Access (System Settings › Keyboard › Keyboard navigation). Open Warm-up from the menu. With Tab, Shift-Tab, the arrow keys and Space, reach every control on Overview, Schedule, Accounts and Settings, and Cmd-1 to Cmd-4 and Cmd-comma. Every confirmation dialog starts on Cancel.
2. **VoiceOver** (Cmd-F5). On Overview, the headline is read first, then the actions. A week mark is read as "13:00 confirmed, button". A result is announced after Warm Up Now and after a copy. On Schedule, the arrow keys move between slots and VoiceOver says "selected".
3. **Light mode.** Switch the Mac to Light. Check that the orange and green marks and the hero symbol are still easy to see on Overview and Schedule.
4. **Larger text.** Set System Settings › Accessibility › Display › Text size to the largest that applies to apps. Check that nothing is clipped in the hero card, the week strip and the Accounts table at the default window size.
5. **Menu bar.** With Reduce transparency and Increase contrast on, the menu-bar symbol is still readable.

Record any failure as a backlog item with a screenshot.
