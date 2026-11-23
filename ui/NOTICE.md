# Third-party notice

Warm-up's menu-bar shell is adapted from [Nameplate](https://github.com/steipete/Nameplate/tree/2d6efa0354065d7dee875a0d2e9e5a57f715d8d4) at revision `2d6efa0354065d7dee875a0d2e9e5a57f715d8d4`, Copyright (c) 2026 Peter Steinberger, under the MIT License. The full license text is in `LICENSES/Nameplate-MIT.txt`.

| Warm-up file | Nameplate source | What changed |
|---|---|---|
| `Sources/WarmupMenu/AppMain.swift` | `Sources/Nameplate/AppMain.swift` | Kept the AppKit `main`, delegate and accessory policy. Removed overlays, splash, fleet, URL commands and Sparkle. Added the explicit binding step. |
| `Sources/WarmupMenu/StatusItemController.swift` | `Sources/Nameplate/StatusItemController.swift` | Kept `NSStatusItem` + `NSMenu` with refresh on open. The menu now shows scheduler state and opens Warm-up's window. |
| `Sources/WarmupMenu/MainWindowController.swift` | `Sources/Nameplate/SettingsWindowController.swift` | Kept the persistent window and toolbar-tab SwiftUI hosting. New panes and a visible-only refresh timer. |
| `Scripts/package_app.sh` | `Scripts/package_app.sh` | Kept the bundle layout and `LSUIElement`. Removed the bundled CLI, Sparkle, URL scheme and upstream signing identity. Signs ad hoc. |

Everything under `Sources/WarmupCore`, the panes and the tests is original to Warm-up. Warm-up uses its own name, bundle identifier (`local.warmup.menu`) and symbols. It ships no Nameplate assets.
