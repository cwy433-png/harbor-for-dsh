# Harbor for DeepSeek Harness

A small macOS app that runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
in a real window, with a real Dock icon, and — the actual point — **quits properly**.

> **Unofficial.** Not affiliated with, endorsed by, or supported by DeepSeek.
> DeepSeek Harness is MIT-licensed software by DeepSeek; this is a third-party
> launcher for it. Bugs here are not their problem. Please do not file issues
> about this app on their repository.

[中文](README.zh.md)

## Why

`dsh web` starts a local server and prints a URL. Closing the browser tab does
not stop the server — it keeps running until you find it and kill it. Harbor
gives the harness an application lifecycle: Cmd+Q stops the server and every
process it started, and if the app is force-quit, the next launch cleans up the
process it left behind.

## Install

Download the `.dmg` from the latest release, open it, and drag the app onto the
Applications folder shown beside it.

**The first time you open it, macOS will refuse.** The app is not notarized
(that requires a paid Apple Developer account). To open it anyway:

1. Double-click the app. macOS says it cannot be opened.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the bottom. Next to the message about Harbor, click **Open Anyway**.
4. Confirm.

You only do this once. If that trade-off is not acceptable to you, build it
yourself instead — see [Building](#building) — which produces an app macOS
does not question.

## First launch

Harbor needs a Node runtime and the harness itself. It tells you exactly what it
is about to download before downloading anything.

- **Node** — if this Mac already has a version the harness can use, Harbor uses
  it and downloads nothing. Only when there is none does it fetch one from
  nodejs.org, verified against the official published checksums.
- **DeepSeek Harness** — installed from the npm registry into Harbor's own
  folder. Around 350 MB; it takes a few minutes.

Nothing is installed system-wide and nothing already on your Mac is modified.

Then open **Settings → Models** inside the app and paste your DeepSeek API key.
It is stored write-only in `~/.dsh/.credentials.yaml`; the interface never
receives it back.

## Updating the harness

Harbor checks for new releases on launch and every few hours, and tells you when
one appears. It never installs one on its own — see
[deliberately does not do](#what-harbor-deliberately-does-not-do). Turn the
checking off with **Harness → Check Automatically**.

DeepSeek Harness is a developer preview whose releases may break compatibility,
so updates are staged rather than applied in place:

1. The new version is downloaded into its own directory. Nothing that currently
   works is touched.
2. Your sessions and settings in `~/.dsh` are copied first.
3. Only once the new version is fully installed does a single symlink swap make
   it current.

A failed or cancelled update therefore leaves the working version working.
**Harness → Roll Back to Previous Version…** returns to the last one.

One caveat worth understanding: the harness stores sessions in a database whose
schema only moves forward, and it rejects formats it does not recognise. If a
newer version has already written to `~/.dsh`, rolling the code back may leave
it unable to read that data. That is why the snapshot is taken — it is in
**Harness → Reveal App Support Folder**, under `snapshots`.

## Using a local checkout

**Harness → Use Local Checkout…** points Harbor at a `deepseek-harness` working
copy you build yourself. Harbor only starts and stops it; it will not run
`git pull` or `pnpm build` for you. **Use Released Version** switches back.

## What Harbor deliberately does not do

- **It will not adopt a server it did not start.** If something is already
  listening on port 3080, Harbor refuses to launch and says so. Taking over a
  stranger's server would mean either killing a process you started in a
  terminal, or quietly declining to shut it down on quit — and shutting down
  cleanly is the entire reason this app exists.
- **It will not install anything system-wide**, and it never writes inside its
  own app bundle.
- **It never installs an update on its own.** It will tell you one exists; the
  decision stays yours. A preview release that breaks your setup should not
  arrive while you are in the middle of something.

## A note on version numbers

Installing a specific harness version does not pin the whole tree. The harness
package depends on its own sixty-odd sub-packages with caret ranges, so npm
resolves them to the newest release in the same `0.1.x` line — install
`0.1.0-rc.3` today and you get its launcher with much newer internals. This is
how the packages are published; every install route has it, including `npx`.

It is why rolling back here means switching back to the previous installed
directory rather than reinstalling the previous version number: the directory
still holds the exact tree you were running, which a fresh install of that
version number would no longer reproduce.

## Building

Requires the Xcode command line tools (`xcode-select --install`). Nothing else —
the icon pipeline and the compiler all ship with macOS.

```bash
./build.sh
```

The result is in `build/`, ad-hoc signed, which is enough to run on the machine
that built it. Add `--dmg` to also package the disk image that ships on the
releases page.

To publish a release that opens without the Privacy & Security detour:

```bash
./build.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize <profile>
```

Create the notarization profile once with `xcrun notarytool store-credentials`.

`Sources/probe/` is a diagnostic tool, not part of the app. It drives the same
runtime and server code without AppKit, so the install, promote, rollback, and
full update sequence can be exercised and timed from a terminal:

```bash
swiftc -framework CryptoKit -o /tmp/harbor-probe \
  Sources/Support.swift Sources/Runtime.swift Sources/Server.swift Sources/probe/main.swift
/tmp/harbor-probe updateflow 0.1.0-rc.6   # stop, snapshot, install, promote, restart, prune
/tmp/harbor-probe promote 0.1.0-rc.3      # just the symlink swap
```

## Where things live

| | |
|---|---|
| Harness runtimes, Node, snapshots, logs | `~/Library/Application Support/Harbor for DeepSeek Harness/` |
| Sessions, settings, credentials | `~/.dsh/` (shared with a terminal `dsh`) |

Harbor never deletes `~/.dsh`. Removing the app and its Application Support
folder leaves your sessions intact.

## License

MIT. See [LICENSE](LICENSE).
