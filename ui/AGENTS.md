# Warm-up menu app (ui/)

Swift package `WarmupMenu`: targets `WarmupCore` (logic, tested), `WarmupMenu` (AppKit/SwiftUI shell), `WarmupCoreTests`. macOS 15+, Swift tools 6.2, no dependencies. Keep it dependency-free.

## Build and test

- Toolchain: Xcode-beta (`xcode-select -p` → `/Applications/Xcode-beta.app/Contents/Developer`). With it, `swift test` needs no plugin-path flags.
- Build: `swift build` (or MobileBuildMCP `swift_package_build`, packagePath = this folder).
- Test: `Scripts/test.sh` / `swift test` (or MobileBuildMCP `swift_package_test`). All Swift Testing tests must pass (368 on 2026-11-27, app 0.7.9).
- `WarmupMenu --status` / `--json` read the live engine: never run them in tests or from a dev build without Fadel's OK.
- Stage the app: `Scripts/package_app.sh /ABSOLUTE/OUT`. It signs ad hoc and never installs or launches.
- After building or testing in the checkout, delete `ui/.build` so the tree matches its recorded hashes.

## Style

- 4-space indent; `.swift-format` holds the settings. Lint only the files you changed: `xcrun swift-format lint <files>` (it picks up `.swift-format` from this folder). Do not reformat untouched files.
- Logic goes in `WarmupCore` with a test; `WarmupMenu` stays a thin shell.
- macOS `Table` cells do not receive `@EnvironmentObject` (0.4 crashed on Accounts): pass the model in as `@ObservedObject`. UI tests cover only Core, so open every tab of a new build before handover.
- A control that mutates without a dialog must send the value the user clicked (`Binding` set's new value), never a flip of the last read state (0.5 review High).
- `WarmupCore` runs only the allowlisted engine commands (`EngineCommand`); never add a shell or free-form argument path.

## Boundaries

- The live engine, LaunchAgent and `~/Applications/Warm-up.app` are Fadel's host install: no installing, launching or launchctl changes without Fadel's OK.
- Third-party code keeps its notice in `NOTICE.md` and `LICENSES/`.
