# Copa

A free, lightweight clipboard history that lives in your MacBook's notch.

Everything you copy is saved automatically. Hover the notch and your history opens as a carousel with these tabs: **All · Text · Links · Images · Files · Colors**.

- **Click** a card to copy it again, then paste with ⌘V.
- **Drag** a card into any app (Mail, Slack, Finder, Notes…).
- **Drop** anything (files, images, text, links) onto the notch. Copa saves it and sorts it into the right tab.
- **Screenshots** you take (⇧⌘3, ⇧⌘4, ⇧⌘5) show up in Images automatically, ready to copy again. The notch shows a spinner the moment you take one.
- **Links** show a rich preview (page image, site icon, title).
- **Right-click** a card to Pin, Rename, Open Link, Show in Finder, or Delete.
- **Rename** gives a clip your own name (Return saves, Esc cancels). The name becomes the card's title and works in search. It's only a label in Copa; files on disk are not renamed.
- **Search** with the field in the top-right. The 📌 button shows pinned clips only.
- **Keyboard:** while Copa is open, ← → move between cards, **Delete** removes the selected one (the latest copy by default), and **Return** copies it and closes Copa.

Copa has no Dock icon. Use the clipboard icon in the menu bar to open Copa, pause capturing, open Settings, or quit.

## Lightweight by design

Copa runs all day in the background, so it's built to be **fast, lightweight and gentle on your battery**. It stays asleep until there's something to do. It never watches your mouse or your screen. And it keeps your images exactly as they are instead of reprocessing them. You shouldn't notice it's running until you reach for it.

## Requirements

- A Mac running **macOS 26** (Tahoe) or later. Copa lives in the notch, and on Macs without one it appears as a hidden hot zone at the top center of the screen.
- **Xcode 26** or later, installed from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835). It's free. The Command Line Tools alone aren't enough to build a Mac app. Open Xcode once after installing it so it can finish setting up.

## Install (recommended)

Run this in Terminal:

```sh
./scripts/install.sh
```

It builds Copa, copies it to `/Applications`, and launches it. To start Copa automatically, turn on **Open Copa at login** in Settings.

## Run from Xcode (for making changes)

1. Double-click `Copa.xcodeproj`.
2. Press **⌘R**.

No Apple Developer account is needed. The app is signed "to run locally".

## First launch: clipboard permission

Recent versions of macOS may ask: *"Copa would like to paste from other apps"*. Choose **Always Allow**, or Copa can't see what you copy.

You can change this later in **System Settings › Privacy & Security › Paste from Other Apps**. Copa's Settings window shows the current status.

## First screenshot: folder permission

To pick up screenshots, Copa needs to read the folder they're saved in (Desktop by default). The first time Copa opens, macOS asks: *"Copa would like to access files in your Desktop folder"*. Choose **Allow**.

You can change this later in **System Settings › Privacy & Security › Files & Folders**. Because Copa isn't signed with a paid Apple developer account, macOS may ask again after you reinstall or update it.

The moment you take a screenshot, the notch widens with a spinner, like the Dynamic Island. When the screenshot lands in Copa it shows a small thumbnail and a checkmark. While the floating thumbnail is on screen, macOS hasn't saved the file yet, so this takes a few seconds; the spinner shows it's on its way.

- **Several in a row:** each one is counted; the notch shows how many are on their way.
- **Screen recordings (⇧⌘5):** saved to **Files** when the recording ends.
- **Copied to the clipboard (⌃⇧⌘4):** appears in Images right away.
- **Dragged into an app or deleted from the thumbnail:** nothing is saved, and the notch shrinks back.
- **Editing in Markup:** the spinner stops after 15 seconds; the screenshot still arrives when you're done.

## Privacy

- Everything stays on your Mac. The only network access is **link previews**: when you copy a link, Copa loads that page's title, image and icon, just like Messages does. You can turn this off in Settings to keep Copa fully offline.
- Items marked as passwords by password managers (1Password, Bitwarden, Keychain…) are never saved.
- Data lives in `~/Library/Application Support/Copa/`: a database plus an `Images` folder. Delete that folder to erase everything.

## Settings

- Open at login
- Save screenshots to Copa
- Show link previews
- Pause capturing
- History size: 100 / 250 / 500 (default) / 1000 / everything. Pinned clips are never removed.
- Clear history

## Project layout

```
Copa/
├── CopaApp.swift            App entry point + menu bar item
├── AppModel.swift           Shared state: store + clipboard monitor
├── Model/                   ClipItem (saved with SwiftData), ClipKind (categories)
├── Services/
│   ├── ClipboardMonitor     Checks the clipboard twice a second
│   ├── ClipClassifier       Decides: text, link, image, file or color
│   ├── ClipStore            Save, de-duplicate, pin, delete, trim history
│   ├── BlobStore            Stores images and thumbnails on disk
│   ├── LinkPreviewLoader    Fetches link title/image/icon (LinkPresentation)
│   ├── ScreenshotWatcher    Picks up new screenshots via Spotlight
│   └── PasteboardWriter     Copy back to clipboard, drag & drop helpers
├── Notch/
│   ├── NotchPanel           The floating window over the notch
│   ├── NotchWindowController  Finds the notch, hover detection, open/close
│   ├── NotchShape           The notch silhouette (animatable)
│   └── NotchView            Root SwiftUI view
└── Views/                   Category tabs, carousel, cards, settings
```

Any new `.swift` file you add inside the `Copa/` folder is picked up by Xcode automatically.

**Contributing:** performance is a rule in this project. Before adding timers, observers or per-item work in views, read the budget and rules in [`CLAUDE.md`](CLAUDE.md) and measure before and after.

### Developer tip

In Debug builds, you can open or close the notch from Terminal:

```sh
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.copa.debug.toggle"), object: nil, userInfo: nil, deliverImmediately: true)'
```

## License

Copyright 2026 Alberto Guzman. Copa is released under the [Apache License 2.0](LICENSE).
