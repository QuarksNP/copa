# Copa

A notch clipboard history for macOS (SwiftUI + AppKit + SwiftData, macOS 26). See README.md for features and layout.

- Build (Debug): `xcodebuild -project Copa.xcodeproj -scheme Copa -configuration Debug -derivedDataPath ~/Library/Caches/Copa/DerivedData.noindex build`
- Install (Release, to /Applications): `./scripts/install.sh`
- Debug builds listen for `com.copa.debug.*` distributed notifications (toggle, snapshot, views, category, rename, key, copy, screenshot) to drive the UI from Terminal; see `NotchWindowController.installMonitors`.

## Notch panel rule

Never change what the open panel shows (search text, selection, clip order, scroll position) while it's animating closed. The carousel is an AppKit scroll view; if it scrolls mid-close, SwiftUI leaves the panel's content stuck inside the closed notch. Do resets after the close finishes (`NotchController.resetAfterClosing`).

## Performance is a rule

Copa runs all day in the background, so it must stay lightweight, low-consumption and fast. Every change must respect this budget (Release build, idle, panel closed):

| Metric | Budget |
|---|---|
| CPU | ≤ 0.1% average |
| Idle wakeups | ≤ 5 per second |
| Memory (RSS) | ≤ 40 MB |

### Rules

- **No always-on work beyond the clipboard poll.** The clipboard check (every 0.5 s) is the only permanent timer. Anything else is event-driven (notifications, KVO, tracking areas, Spotlight queries). Short-lived polling is allowed only while something is actually happening, e.g. the screenshot check runs only while macOS's screenshot tool is open.
- **No system-wide event monitors while idle.** Never watch every mouse movement; hover uses the notch window's `NSTrackingArea`. Global monitors (such as click-outside) are installed only while the panel is open and removed when it closes.
- **Heavy work off the main thread.** Image decoding/encoding, hashing and file reads go through `Task.detached` or nonisolated helpers.
- **Don't redo work.** Keep image bytes as-is (no re-encoding PNG/JPEG/HEIC/GIF); decode only small thumbnails; read image size from file headers.
- **Views never touch unbounded data.** Clips can be megabytes: cards, names and search use a prefix of the text. Icons and thumbnails come from bounded `NSCache`s in `ImageCache`, never from disk or `NSWorkspace` on every redraw.
- **Views must survive deleted clips.** A card can be drawn during its removal animation after SwiftData has destroyed its data; check `isDeleted` / `modelContext` before reading a clip.

### Measuring

Run the Release build (`./scripts/install.sh`), wait ~30 s after launch, and don't touch the Mac while measuring (copying, hovering the notch or taking screenshots makes Copa do real work and skews the numbers). Then:

```sh
PID=$(pgrep -x Copa)
t() { ps -o time= -p $PID | awk -F: '{print ($1*60)+$2}'; }
a=$(t); sleep 20; b=$(t); echo "CPU: $(echo "scale=2; ($b - $a) * 5" | bc)%"
top -l 2 -s 10 -pid $PID -stats pid,idlew | tail -1   # idle wakeups per 10 s
ps -o rss= -p $PID | awk '{printf "RSS: %.1f MB\n", $1/1024}'
```

Measure before and after any change that adds timers, observers, monitors, or per-item work in views.
