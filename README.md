# Notchprompt

<p align="center">
  <img src="assets/banner.png" alt="Notchprompt Banner" width="100%">
</p>

Native macOS notch-adjacent teleprompter for presentations and recordings.

## Quick Demo

> Demo assets below are placeholders. Replace with real captures before public
> launch.

<!--
![Notchprompt hero screenshot](docs/media/hero.png)
*Hero view of the overlay panel and settings workflow.*

![Notchprompt scrolling demo GIF](docs/media/notchprompt-demo.gif)
*In-use scrolling demo with start/pause and speed adjustments.*
-->

## Features

- Menu bar utility workflow (`NP` status item).
- Notch-adjacent floating overlay with transport controls.
- Start/pause, reset, and jump back 5 seconds.
- Adjustable speed, font size, overlay width, and overlay height.
- Optional countdown before scrolling starts.
- Import/export plain text scripts.
- **Listen mode** — tap the mic in the notch (or `⌥⌘L`) to transcribe a background
  question and get an AI answer in the notch.
- **Provider picker + key entry inside the notch** — OpenAI, DeepSeek, Groq,
  OpenRouter, Together AI, or any OpenAI-compatible endpoint.
- **Automatic fallback provider** — e.g. DeepSeek — retried when the primary fails
  (rate limit, 5xx, network, invalid key).
- API keys are stored in the **Keychain**, never in preferences.
- Overlay is always excluded from screen recording and screen sharing.

## Requirements

- macOS 14.0 or later.
- Apple Silicon or Intel Mac.
- Microphone and Speech Recognition permission (requested on first use).
- An API key from an OpenAI-compatible provider for the Listen feature.

## Install (Recommended)

1. Open GitHub Releases:
   `https://github.com/saif0200/notchprompt/releases`
2. Download the latest `.dmg` release asset.
3. Open the DMG and drag `notchprompt.app` to `Applications`.
4. Launch `notchprompt.app`.

### Unsigned Build Note

This build is currently unsigned/unnotarized, so macOS may show security prompts.

If macOS shows:

- `Apple could not verify "notchprompt" is free of malware...`
- or `"notchprompt" is damaged and can’t be opened`

run:

```bash
xattr -cr /Applications/notchprompt.app
open /Applications/notchprompt.app
```

If it is still blocked:

1. Open `System Settings -> Privacy & Security`.
2. Click **Open Anyway** for `notchprompt`.
3. Launch again.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌥⌘P` | Start / Pause |
| `⌥⌘R` | Reset scroll |
| `⌥⌘J` | Jump back 5s |
| `⌥⌘H` | Toggle Privacy Mode |
| `⌥⌘O` | Toggle overlay visibility |
| `⌥⌘L` | Listen — start/stop mic, send captured question to AI |
| `⌥⌘=` | Increase speed |
| `⌥⌘-` | Decrease speed |

## Listen & AI (Background Q&A)

The notch has a mic button that answers questions asked out loud on a call or in
a meeting.

**Setup**

1. Tap the **gear** in the notch (or the **Set AI key** pill — it appears when no
   key is configured yet).
2. Pick a provider chip: **OpenAI**, **DeepSeek**, **Groq**, **OpenRouter**,
   **Together AI**, or **Custom** for any OpenAI-compatible endpoint.
3. Paste the provider's API key (`↗` opens that provider's key page), then
   **Test** to verify.
4. Optionally turn on a **Fallback provider** (DeepSeek is a good choice) so a
   failed primary request is retried automatically.

Keys are saved to the macOS **Keychain**. The same editor is available in
`Settings… → Listen & AI`.

**Using it**

- Tap the mic (or `⌥⌘L`) to start listening. The transcript appears live.
- With **Auto-send after pause** on (default), ~1.4s of silence auto-sends the
  captured question. Turn it off to send manually by tapping the mic again.
- The answer appears in a card in the notch with **Copy** and **To script**
  (appends the answer to your scrolling script).
- **Continuous listening** resumes capture after each answer for follow-up
  questions.

Speech recognition uses Apple's on-device model when available, otherwise Apple's
servers.

## Privacy

The overlay window is always created with `NSWindow.SharingType.none` and the
value is re-asserted on every show, reposition, and via a KVO observer plus a
periodic timer, so the notch is not included in `screencapture`,
ScreenCaptureKit/`SCStream` streams, or shared-window captures.

This is macOS's documented best-effort guarantee; no app can exclude its windows
from every possible capture method (for example a camera pointed at the screen).

## Build From Source

```bash
git clone https://github.com/saif0200/notchprompt.git
cd notchprompt
open notchprompt.xcodeproj
```

CLI build:

```bash
xcodebuild -project notchprompt.xcodeproj -scheme notchprompt -configuration Debug build
```

## License

MIT. See `LICENSE`.
