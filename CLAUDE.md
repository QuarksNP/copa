# Copa

A notch clipboard history for macOS (SwiftUI + AppKit + SwiftData, macOS 26). See README.md for features and layout.

- Build (Debug): `xcodebuild -project Copa.xcodeproj -scheme Copa -configuration Debug -derivedDataPath ~/Library/Caches/Copa/DerivedData.noindex build`
- Install (Release, to /Applications): `./scripts/install.sh`
- Debug builds listen for `com.copa.debug.*` distributed notifications (toggle, hold, snapshot, views, category, search, rename, key, copy, screenshot, newfolder, openfolder, delfolder, delfolderall, file, drop, newsection, delsection, delsectionall) to drive the UI from Terminal; see `NotchWindowController.installMonitors`. `hold` keeps the panel open while you script it, `views` dumps the tab, path, selection, folders and sections, and `drop` runs a drag and drop without a mouse (posting real mouse events needs Accessibility, which a terminal usually doesn't have).

## Notch panel rule

Never change what the open panel shows (search text, selection, clip order, scroll position) while it's animating closed. The carousel is an AppKit scroll view; if it scrolls mid-close, SwiftUI leaves the panel's content stuck inside the closed notch. Do resets after the close finishes (`NotchController.resetAfterClosing`).

## Folders and sections

A clip lives in exactly one place: loose in the built-in history, in a section the user made, or in
one folder (which belongs to a section, or to the built-in history). `ClipItem.sectionID` /
`folderID` say where, and `isFiled` mirrors them so trimming the history can filter on a plain Bool.
Moving a clip always goes through `ClipStore.file(_:inFolder:section:)`, which keeps the three in step.

Folders are linked by plain ids (`parentID`, `sectionID`), not SwiftData relationships: the carousel
filters every clip on each redraw, and reading an id costs nothing while following a relationship
would fault whole objects in.

- **Folders remember what they hold.** `kindsMask` (which kinds are anywhere inside) and `itemCount`
  are kept up to date by `ClipStore+Filing`, so a tab can decide whether to show a folder without
  walking it. Any change to where something is filed must end in `refreshStats(from:)` — or
  `refreshAllStats()` when several branches move at once.
- **Views never walk a folder.** Read `kindsMask` / `itemCount`; never count a folder's contents
  while drawing.
- **Folder cards survive deletion** for the same reason clip cards do: check `isDeleted` /
  `modelContext` before reading one.
- **Dropping goes through one path.** `ClipFolder.canDrop` decides whether a card may land
  somewhere and `AppModel.acceptDrop` does it, for both the folder cards and the path bar. Add a
  new drop target by calling those two, not by rewriting the rules.
- **Deleting is never silent.** A folder or section with something in it offers both outcomes
  ("…, Keep Clips" and "… & Contents"); the Delete key only removes an empty folder.

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
