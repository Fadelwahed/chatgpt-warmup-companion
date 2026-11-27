# Warm-up for ChatGPT accounts

Warm-up sends one small request ("a warm-up") to each of your ChatGPT accounts at times you choose, such as 08:00, 13:00 and 18:00. A ChatGPT plan's usage window starts with the first request. So a warm-up sent before you start work starts that window early, and it resets sooner while you are working.

It has two parts:

- **The engine** is a small command-line program for Node 22, with no dependencies. A macOS LaunchAgent wakes it every 30 seconds, and it sends a warm-up only during a scheduled minute. It reads your accounts from [codex-router](https://github.com/duolahypercho/codex-router), so codex-router must already be installed and signed in.
- **The Warm-up app** is an optional menu-bar app for macOS (Swift, in [`ui/`](ui/)). It shows the next warm-up, recent results, the schedule and each account. You can pause, resume, run now, edit times and set vacations from it. It only runs the engine's own commands.

> **Use it at your own risk.** Warm-up is an independent project, not affiliated with or endorsed by OpenAI. Each warm-up is a real request, and it counts against your plan whether it succeeds, fails or ends uncertain. A successful warm-up proves only that the account answered at that moment. It does not add quota, keep a session warm or renew sign-ins. Use it only with ChatGPT accounts you own, and check that automated requests are allowed under your plan's terms before you use it.

## Contents

- [Requirements](#requirements)
- [Install the engine](#install-the-engine)
- [Install the app](#install-the-app)
- [Everyday use](#everyday-use)
- [Change the schedule](#change-the-schedule)
- [Update](#update)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [How it stays safe](#how-it-stays-safe)

## Requirements

- **A Mac with Apple silicon**, on macOS 15 or later. The engine accepts only Homebrew's `node@22` at `/opt/homebrew/opt/node@22/bin/node`, which is the Apple silicon path.
- **A home folder whose path has no spaces.** The LaunchAgent check can't yet handle a space in the engine's path.
- **Node 22.19 or later from Homebrew:**

  ```sh
  brew install node@22
  ```

  You don't need to link it or put it on your `PATH`. The engine is always called through its full path.

- **codex-router at revision `7e7350e7`**, installed in its default folder (`~/.local/share/codex-router`), with at least one ChatGPT account signed in. The engine reads 13 of codex-router's source files directly and checks each against a recorded SHA-256 digest ([`compat/compatibility.json`](compat/compatibility.json)). It refuses to run against any other version (`unreviewed_source`). Install codex-router by following its own README, then pin it:

  ```sh
  git -C ~/.local/share/codex-router checkout 7e7350e7b579b8b5b2085ee4bafc216c13e2c6d9
  ```

  If you update codex-router later and those files change, warm-ups stop until this project publishes a new compatibility record.

- **For the app only:** a Swift 6.2 or later toolchain (Xcode 26 or later, or the matching Command Line Tools).

## Install the engine

Every command below is safe to copy as written. Each engine command prints one JSON object. Its `outcome` and `reason` fields tell you what happened, and its exit code is listed in [Exit codes](#exit-codes).

### 1. Get the code

```sh
git clone https://github.com/Fadelwahed/chatgpt-warmup-companion.git
cd chatgpt-warmup-companion
```

### 2. Copy the engine into place

```sh
scripts/install-engine.sh
```

The script does the following:

1. Checks for macOS, Homebrew `node@22` and the reviewed codex-router source.
2. Creates `~/.local/share/codex-router-warmup` (mode `0700`).
3. Copies the four engine modules into it.
4. Writes the compatibility record and an install marker (`instance.json`) that names codex-router's folders.

It reads no account, sends nothing and creates no LaunchAgent. It stops without changing anything if the folder or LaunchAgent already exists. If codex-router lives somewhere else, set `CODEX_ROUTER_SOURCE=/path/to/codex-router` before running it.

To save typing, define this shell function in your Terminal session (it works in zsh and bash). Every later command uses it:

```sh
warmup() { /opt/homebrew/opt/node@22/bin/node "$HOME/.local/share/codex-router-warmup/warmup.mjs" "$@"; }
```

To keep it in new Terminal windows, add the same line to `~/.zshrc`.

### 3. Find your accounts

```sh
warmup setup
```

`setup` reads codex-router's account list once. It records each eligible account as an **enrollment**, with an ID like `enr_…`, that uses the model `gpt-6-luna`. New enrollments start enabled. Accounts it can't use are listed under `excluded` with a reason. It doesn't send anything. An account you add to codex-router later joins only when you run `warmup enroll --account <codex-router account ID>`.

Check what it found:

```sh
warmup list
```

### 4. Send one warm-up by hand

```sh
warmup run
```

This sends one warm-up to every enabled enrollment, right now. A successful manual run is the proof the schedule needs before it can start: it confirms the account, model and request format together. To try a single account, add `--account enr_…`.

### 5. Turn on the schedule

```sh
warmup schedule enable
```

This writes and loads the LaunchAgent `~/Library/LaunchAgents/local.codex-router-warmup.plist`. From then on, warm-ups go out at 08:00, 13:00 and 18:00 in your Mac's time zone, with no Terminal open. A slot passes unsent while your Mac is asleep or off, and the engine never sends it late. To have a sleeping Mac wake for every warm-up, book a one-time wake 5 seconds into each warm-up of the next 4 weeks:

```sh
scripts/schedule-wakes.sh --dry-run   # show the pmset commands first
scripts/schedule-wakes.sh             # book 28 days; asks for your password once
scripts/schedule-wakes.sh --days 7    # book fewer days (1 to 28)
```

Run it as yourself, not with `sudo`. It replaces only the wakes it booked before (owner `warmup` in `pmset -g sched`), so rerun it every 4 weeks and after any schedule change; `--cancel` removes them. A wake cannot start a Mac that is shut down. `pmset` keeps a single repeating wake, so `sudo pmset repeat wakeorpoweron MTWRFSU 07:55:00` covers only your first slot.

With the lid closed on battery, a booked wake lasts only about 30 seconds; plugged in, the engine keeps the Mac awake for the warm-up. `scripts/wake-test.sh` measures this without sending anything: it books four test wakes 4 minutes apart (owner `waketest`, never `warmup`) and a watcher logs, at each wake, how long the Mac stays awake with no assertion or with `caffeinate -i`, `-u` or `-s -i`, and when a name lookup of `chatgpt.com` succeeds. Unplug any external display, run it, close the lid until the time it prints, then run `scripts/wake-test.sh --report`. `--quick` books one test wake 2 minutes out with every hold at once (`caffeinate -u -s -i`); close the lid for about 5 minutes. Logs go to `~/Library/Logs/warmup-wake-test/`; `--dry-run` and `--self-test` change nothing; `--cancel` removes the test wakes and stops the watcher.

## Install the app

The app is optional. Without it, everything still works from the command line.

```sh
cd ui
swift build
Scripts/package_app.sh "$HOME/Applications"
```

This builds `Warm-up.app` and signs it ad hoc for your Mac only, so don't copy it to another Mac. Before the app runs any command, link it to your engine. Quit the app if it is open, then:

1. Read the engine's build digest:

   ```sh
   warmup status | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["engineBuild"])'
   ```

2. Create the link, putting that digest after `--expect-build`:

   ```sh
   ~/Applications/Warm-up.app/Contents/MacOS/WarmupMenu --provision-binding \
     --node /opt/homebrew/opt/node@22/bin/node \
     --script "$HOME/.local/share/codex-router-warmup/warmup.mjs" \
     --expect-build sha256:PASTE_THE_DIGEST
   ```

3. Open the app:

   ```sh
   open ~/Applications/Warm-up.app
   ```

The link is saved in `~/Library/Application Support/local.warmup.menu/engine-binding.json`. It holds only the Node path, the script path, the build digest and the install ID: no accounts and no secrets. If the engine's files ever change, the app shows **Setup required** and only reads status until you link it again. That way an engine replaced by mistake can't take orders from the app. [`ui/README.md`](ui/README.md) describes every screen, the alerts and the app's known limits.

## Everyday use

| Task | Command |
|---|---|
| See the next warm-up, recent results and any problem | `warmup status` |
| List accounts and enrollments | `warmup list` |
| Send a warm-up now (all accounts, or one) | `warmup run` / `warmup run --account enr_…` |
| Pause or resume the schedule | `warmup schedule disable` / `warmup schedule enable` |
| See the next seven days (or up to 28) | `warmup schedule inspect` / `warmup schedule inspect --days 28` |
| See past warm-ups | `warmup history` |
| See how long each account took to answer | `warmup timing` |

In the app, the same actions are in the window and the menu-bar menu. The app also shows each account's usage window as last reported by ChatGPT. It can send alerts when a warm-up fails or a slot is missed.

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | Done, or nothing was due |
| 1 | At least one account failed, was blocked or ended uncertain. Every result is kept |
| 2 | The command or the install is invalid. `reason` says what to fix |
| 3 | Another Warm-up command holds the lock. Wait and try again yourself; it never retries on its own |
| 4 | `run` found no enabled enrollment, so nothing was sent |

## Change the schedule

All schedule edits take effect from the next day unless you add `--today`. Add `--preview` to any edit to see the result without saving it.

```sh
warmup schedule add 21:05              # a new daily time
warmup schedule remove 18:00           # drop a daily time
warmup schedule move 08:00 09:15       # move a daily time
warmup schedule move 08:00 07:30 --today   # move only today's slot
warmup schedule weekdays 1,2,3,4,5     # Monday to Friday only (1 = Monday)
warmup schedule exclude 2026-12-24 2026-12-31   # a vacation, both dates included
warmup schedule cap enr_… 2            # at most 2 scheduled warm-ups a day for one account
warmup schedule undo                   # undo today's last add, remove or move
```

Slots must be at least 15 minutes apart, across midnight too. The engine refuses an edit that would put two slots closer, and the refusal says why. [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md) has the full rules: time zones, daylight-saving days, vacations, caps and choosing which accounts the schedule covers.

## Update

To install a newer engine without losing its state or history:

1. Get the new code and pause the schedule. Go on only if the reply's `reason` is `schedule_disabled`. If it is `lock_busy`, wait a moment and pause again:

   ```sh
   git pull
   warmup schedule disable
   ```

2. Keep a copy of the current engine, then copy in the new one:

   ```sh
   mkdir -m 700 -p ~/warmup-backup
   cp -p ~/.local/share/codex-router-warmup/*.mjs ~/warmup-backup/
   cp warmup.mjs runtime.mjs router-reader.mjs chatgpt-probe.mjs ~/.local/share/codex-router-warmup/
   chmod 600 ~/.local/share/codex-router-warmup/*.mjs
   ```

3. Check the new engine. `status` must report `"outcome":"ready"`, `"compatibility":"ready"` and the new `engineVersion`. Only then resume:

   ```sh
   warmup status
   warmup schedule enable
   ```

If `outcome` isn't `ready`, leave the schedule paused, copy the files from `~/warmup-backup` back and open an issue. If only `compatibility` is `blocked`, the new release supports a different codex-router revision. Its release notes then explain how to apply the new `compat/compatibility.json` with `warmup maintain` ([engine reference](docs/ENGINE-REFERENCE.md#maintenance-candidate)). After any engine update, link the app again ([Install the app](#install-the-app), steps 1 and 2). To update the app, quit it, run `Scripts/package_app.sh "$HOME/Applications"` again and reopen it.

## Uninstall

```sh
warmup schedule disable
warmup remove
```

`remove` unloads and deletes the LaunchAgent, then deletes `~/.local/share/codex-router-warmup` together with its state and history. It never touches codex-router or your accounts. To remove the app, quit it, then delete `~/Applications/Warm-up.app` and `~/Library/Application Support/local.warmup.menu`.

## Troubleshooting

| `reason` | What it means | What to do |
|---|---|---|
| `node_runtime_unqualified` | Node isn't Homebrew `node@22` at `/opt/homebrew/opt/node@22` | `brew install node@22` |
| `unreviewed_source` | codex-router's files differ from the reviewed revision | Check out `7e7350e7` (see [Requirements](#requirements)) |
| `incomplete_initialization` | `setup` hasn't run yet, or a first `setup` stopped partway | If `setup` has never run, run it. If it stopped partway, start over as described below |
| `registry_blocked` | codex-router was busy or its account list couldn't be read during `setup` | Let codex-router finish what it's doing, then start over as described below |
| `job_ownership_unknown`, `existing_job_or_plist` | A LaunchAgent named `local.codex-router-warmup` already exists | Remove the old install first (`warmup remove` from it) |
| `ownership_overlap` | Two of the configured folders overlap, or don't exist yet | Make sure codex-router has run once and `~/Library/LaunchAgents` exists |
| `lock_busy` (exit 3) | Another Warm-up command is running | Wait a moment and run it again. A lock left by a crashed command clears itself once its owner is proven gone |
| `slot_overlap_risk` | A manual `run` would collide with a scheduled slot | Wait until the slot has run, or use the app's **Run Anyway** |

**Starting over after a failed first `setup`.** A first `setup` that stops partway can't be retried, and `remove` doesn't accept it either. Nothing has been sent at that point and no LaunchAgent exists, so it is safe to delete the install and run the installer again. First check that no LaunchAgent was created: the next command must print nothing. Then delete and reinstall:

```sh
ls ~/Library/LaunchAgents/local.codex-router-warmup.plist 2>/dev/null
rm -r ~/.local/share/codex-router-warmup
scripts/install-engine.sh
```

Do this only before your first successful `setup`. After that, the install holds history and send records, so use `warmup remove`.

`status` also reports the work lock (`workLock.state`), unresolved sends and missed slots. [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md) covers recovery after a crash or a power loss.

## Development

```sh
/opt/homebrew/opt/node@22/bin/node test/run.mjs   # engine tests
cd ui && Scripts/test.sh                           # app tests (Swift Testing)
```

The engine tests run inside a private temporary home folder. They load a guard that blocks any read or write outside it, any network access and any `launchctl` call. Run them through `test/run.mjs`, not plain `node --test`. They never touch a real install or a real account.

| Path | What's there |
|---|---|
| `warmup.mjs` | Command-line entry point and argument parsing |
| `runtime.mjs` | Install checks, locks, scheduler, state and LaunchAgent handling |
| `router-reader.mjs` | Read-only access to codex-router's accounts, checked against `compat/compatibility.json` |
| `chatgpt-probe.mjs` | The warm-up request itself |
| `scripts/install-engine.sh` | First-time install |
| `test/` | Engine tests and the fixtures the app's tests share |
| `tools/extract-ui-fixtures.mjs` | Regenerates the app's test fixtures after an engine output change |
| `ui/` | The macOS menu-bar app ([`ui/README.md`](ui/README.md), [`ui/AGENTS.md`](ui/AGENTS.md)) |
| `docs/ENGINE-REFERENCE.md` | Full engine reference |

Pull requests are welcome. Keep the engine dependency-free and add a test for every behavior change.

## How it stays safe

- **No secrets stored.** Warm-up reads each account's sign-in from codex-router at send time and keeps no copy. Its own files hold only account IDs, the schedule and results, and the results are stripped of raw server text.
- **Never retries.** A failed or uncertain warm-up is recorded as it happened. The engine never retries, refreshes a sign-in, switches accounts or falls back to another model.
- **Private files.** The install folder must be `0700` and owned by you, with no symlinks, and every file in it `0600`. Otherwise the engine refuses to run.
- **One command at a time.** A lock stops two commands, or the scheduler and you, from overlapping. Schedule edits can carry the expected revision, so an edit based on an old `status` is refused.
- **Late slots are skipped.** A slot missed while the Mac slept is recorded as missed, not sent late.

## License

[MIT](LICENSE). The app includes code adapted from Nameplate (MIT); see [`ui/NOTICE.md`](ui/NOTICE.md).
