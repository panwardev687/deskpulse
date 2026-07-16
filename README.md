<p align="center">
  <img src="assets/icon.png" width="128" alt="DeskPulse app icon">
</p>

<h1 align="center">DeskPulse</h1>

<p align="center"><b>Free, open-source clipboard manager, text expander, and file converter for Mac in one native app. Clipboard history with search and pins, snippets that expand as you type, and HEIC/JPG/PNG and audio conversion - with zero network access.</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen" alt="Zero dependencies">
</p>

## What is DeskPulse?

DeskPulse is a free alternative to Paste, TextExpander, and Permute. It bundles the three desk utilities people usually pay subscriptions for into one native Swift app: a clipboard history manager, a text snippet expander, and a drag-and-drop image and audio converter. The binary is about 1 MB, there is no telemetry, and nothing ever touches the network.

## Features

| Tool | What it does |
|---|---|
| **Clipboard History** | Every copy is captured: text, images, and files. Search it, pin favorites so they never expire, click to copy back, or copy as plain text to strip formatting. Anything a password manager marks confidential is never recorded. |
| **Text Snippets** | Type `;addr` anywhere and it becomes your full address. Triggers expand in every app, with `{date}`, `{time}`, and `{clipboard}` placeholders filled at expansion time. |
| **File Converter** | Drag in HEIC, PNG, JPG, TIFF, WebP, GIF, or BMP images and convert between formats with quality and resize controls. Audio converts between MP3 sources and M4A, WAV, AIFF, or FLAC. Originals are always kept and existing files are never overwritten. |
| **Menu bar popover** | Your last eight clips one click away, next to the clock. DeskPulse keeps working when the window is closed. |

Conversion runs on the `sips` and `afconvert` tools that ship inside macOS, so DeskPulse adds no codecs, no bundled ffmpeg, and no dependencies.

## DeskPulse vs the paid apps

| | DeskPulse | Paste | TextExpander | Permute | Maccy |
|---|---|---|---|---|---|
| Price | Free | $30/yr | $40/yr | $15 | Free |
| Open source | Yes | No | No | No | Yes |
| Clipboard history + search | Yes | Yes | No | No | Yes |
| Pinned favorites | Yes | Yes | No | No | Yes |
| Image and file clips | Yes | Yes | No | No | Partial |
| Text expansion snippets | Yes | No | Yes | No | No |
| Image conversion (HEIC to JPG) | Yes | No | No | Yes | No |
| Audio conversion | Yes | No | No | Yes | No |
| Video conversion | No | No | No | Yes | No |
| iCloud sync across devices | No | Yes | Yes | No | No |
| Telemetry / network calls | None | Yes | Yes | Some | None |

Each of those apps is good at its single job, and the sync features are real advantages if you live on multiple devices. DeskPulse exists because most people need 80% of all three, on one Mac, without three subscriptions.

## Install

Build from source (needs Xcode Command Line Tools: `xcode-select --install`):

```sh
git clone https://github.com/panwardev687/deskpulse.git
cd deskpulse
./build.sh
open DeskPulse.app
```

The build is a single `swiftc` invocation and takes a few seconds. No Xcode project, no package manager, no dependencies.

To start DeskPulse at login, flip the toggle in Settings inside the app.

## Frequently asked questions

### How do I see my clipboard history on Mac?

macOS only remembers the last thing you copied. DeskPulse fixes that: it records everything you copy (text, images, and files) into a searchable history. Click the clipboard icon in the menu bar for your recent clips, or open the app to search hundreds of items and pin the ones you reuse.

### How do I paste without formatting on Mac?

Copied text often drags fonts and colors along with it. In DeskPulse, right-click any text clip and choose "Copy as Plain Text", then paste normally. You get the characters only, no styling. This works on anything in your history, not just the most recent copy.

### How do I convert HEIC photos to JPG on Mac?

Drop HEIC files onto DeskPulse's File Converter pane, pick JPG, choose a quality, and click Convert. Conversion happens locally through macOS's own imaging engine, so photos are never uploaded anywhere. Originals stay untouched; converted copies appear next to them. PNG, TIFF, and HEIC output work the same way.

### How do I create text shortcuts that expand automatically on Mac?

macOS has built-in text replacement, but it is unreliable in many apps and hard to manage. DeskPulse's snippets expand in any app: define a trigger like `;sig`, type it anywhere, and the expansion replaces it instantly. Placeholders like `{date}` and `{clipboard}` are filled at the moment of expansion.

### Does DeskPulse record passwords?

No. Password managers mark sensitive copies with a standard "concealed" flag (`org.nspasteboard.ConcealedType`), and DeskPulse skips anything carrying it. History is stored locally in `~/Library/Application Support/DeskPulse`, never synced, never transmitted. You can also delete any item or clear unpinned history at any time.

### Is DeskPulse a good free alternative to Paste or TextExpander?

For clipboard history, pinned favorites, plain-text pasting, and everyday snippets: yes. Paste has a prettier visual browser and iCloud sync; TextExpander has team sharing and fill-in forms. If you need those, they are worth their price. If you need the core features on one Mac, DeskPulse does them for free and you can read every line of its source.

## Permissions

- **Accessibility** - only needed for text snippets (watching for triggers and typing expansions). Clipboard history and file conversion work without it. macOS asks on first use: System Settings → Privacy & Security → Accessibility → enable DeskPulse.

DeskPulse makes zero network connections. No analytics, no telemetry, no update phone-home. The only outbound links are the GitHub buttons in Settings.

## Repository layout

```
DeskPulseApp/           <- the app (start here)
  Main.swift              app shell + sidebar navigation
  StatusBar.swift         menu bar icon + quick-clips popover
  ClipboardModel.swift    clipboard capture engine + persistence
  ClipboardView.swift     history pane with search and pins
  SnippetsModel.swift     text expansion engine (event tap)
  SnippetsView.swift      snippet editor pane
  ConvertView.swift       file converter (sips / afconvert)
  Settings.swift          preferences and launch-at-login
  Shared.swift            common helpers
build.sh                <- builds DeskPulse.app
scripts/make_icon.swift   regenerates the app icon programmatically
```

## Contributing

Issues and PRs welcome. The codebase is intentionally simple: one view file per pane, models are plain `ObservableObject`s, helpers live in `Shared.swift`. Build with `./build.sh`, no other tooling required.

## More free Mac tools

- [MacPulse](https://github.com/panwardev687/macpulse) - system monitor and cleaner: CPU temperature, System Data cleanup, duplicate finder, app uninstaller, disk space map.

## Support

If DeskPulse replaced a subscription for you, consider [sponsoring development](https://github.com/sponsors/panwardev687).

## License

[MIT](LICENSE)
