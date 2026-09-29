# Notchprompt

<p align="center">
  <img src="assets/banner.png" alt="Notchprompt Banner" width="100%">
</p>

Native macOS notch-adjacent teleprompter for presentations and recordings, with
an AI assistant that answers background questions while you stay on camera.

## Quick Demo

> Demo assets below are placeholders. Replace with real captures before public
> launch.

<!--
![Notchprompt hero screenshot](docs/media/hero.png)
*Hero view of the overlay panel and settings workflow.*

![Notchprompt scrolling demo GIF](docs/media/notchprompt-demo.gif)
*In-use scrolling demo with start/pause and speed adjustments.*

![Notchprompt listen demo](docs/media/notchprompt-listen.png)
*Listen mode: question captured in the notch, answer shown in the overlay.*
-->

## Features

### Teleprompter

- Menu bar utility workflow (`NP` status item).
- Notch-adjacent floating overlay with transport controls.
- Start/pause, reset, and jump back 5 seconds.
- Adjustable speed, font size, overlay width, and overlay height.
- Optional countdown before scrolling starts, plus manual trackpad scrolling.
- Import/export plain text scripts.

### Listen — AI answers for background questions

- **One-tap capture** — a mic control in the notch (or `⌥⌘L`) transcribes a
  question asked out loud on a call and answers it in the overlay.
- **Streamed answers** — the response appears word by word, so you can start
  speaking before it finishes. Reasoning models (DeepSeek R1) are handled
  correctly: their internal reasoning is kept out of the answer you read.
- **Provider picker + key entry inside the notch** — OpenAI, DeepSeek, Groq,
  OpenRouter, Together AI, or any custom OpenAI-compatible endpoint.
- **Automatic fallback provider** — e.g. DeepSeek — retried whenever the primary
  fails (rate limit, 5xx, network error, or invalid key).
- **Hands-free or manual send**, with a tunable pause-before-sending, and
  continuous listening for follow-up questions.
- **Spends less.** Small talk and filler are filtered out before a request is
  made, and answers can be re-used from a local cache.
- API keys are stored in the **Keychain**, never in preferences.
- Uses Apple's on-device speech model when available, otherwise Apple's servers.

### Privacy

- The overlay is **always** excluded from screen recording and screen sharing —
  it cannot be switched off.
- Keys live in the Keychain; nothing sensitive is written to preferences.

## Roadmap

Planned improvements are tracked in [PLAN.md](PLAN.md) — streaming answers,
context-aware replies, question gating, answer caching, script library, and
more.

## Requirements

- macOS 14.0 or later.
- Apple Silicon or Intel Mac.
- Microphone and Speech Recognition permission (requested on first use of Listen).
- An API key from an OpenAI-compatible provider, for the Listen feature only.

## Install (Recommended)

1. Open GitHub Releases:
   `https://github.com/Aarondio/notchprompt/releases`
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
| `⌥⌘O` | Toggle overlay visibility |
| `⌥⌘L` | Listen — start/stop mic, send captured question to AI |
| `⌥⌘[` | Narrower notch |
| `⌥⌘]` | Wider notch |
| `⌥⌘=` | Increase speed |
| `⌥⌘-` | Decrease speed |
| `⌥⌘H` | Hidden from capture (enforced — shown for reference only) |

## Notch Size

The overlay width can be changed three ways:

- **Presets** in `Settings → Appearance` — Compact (420pt), Default (600pt),
  Wide (900pt), Ultra (1200pt).
- **Slider** over the same range, for fine control.
- **Keyboard** — `⌥⌘[` and `⌥⌘]` nudge the width in 40pt steps, so you can
  resize without opening Settings mid-call. The status menu items show the
  current width.

The permitted range follows the target display, capped at 90% of its width, so
the panel can never overflow the edges of a smaller screen. Presets that the
current display is too narrow to reach are dimmed.

## Notch Layout

```
+---------------------------------------------------------------+
|  [play] [jump back] [mic]   [paste] [clear] [-] [+] [gear] [x]|
|                                                               |
|               transcript / answer card (when active)          |
+---------------------------------------------------------------+
  \________ left group _______/                        \__ right group __/
```

The **mic** sits with the transport controls on the left. The **gear** opens the
AI provider and key panel. Answers, live transcripts, and errors appear in a
card at the bottom of the overlay.

## Listen & AI (Background Q&A)

### Setup

1. Tap the **gear** in the notch to open the provider panel.
2. Choose a provider from the segmented control.
3. Paste the API key in **API Key** (the `↗` button opens that provider's key
   page), then press **Test** to verify the connection.
4. Optionally enable a **Fallback provider** so a failed primary request is
   retried automatically. DeepSeek is a good, inexpensive fallback.

Keys are saved to the macOS **Keychain**. The same editor, plus the system prompt,
temperature, max tokens, and a question/answer history, is in
`Settings… → Listen & AI` (also reachable from the panel's *Full Settings…*).

### Supported providers

| Provider | Base URL | Key page | Example model |
| --- | --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | [platform.openai.com](https://platform.openai.com/api-keys) | `gpt-4o-mini` |
| DeepSeek | `https://api.deepseek.com` | [platform.deepseek.com](https://platform.deepseek.com/api_keys) | `deepseek-chat` |
| Groq | `https://api.groq.com/openai/v1` | [console.groq.com](https://console.groq.com/keys) | `llama-3.3-70b-versatile` |
| OpenRouter | `https://openrouter.ai/api/v1` | [openrouter.ai](https://openrouter.ai/keys) | `openai/gpt-4o-mini` |
| Together AI | `https://api.together.xyz/v1` | [api.together.xyz](https://api.together.xyz/settings/api-keys) | `meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| Custom | *any OpenAI-compatible `/chat/completions` endpoint* | — | — |

Bring your own key. Requests go straight from your Mac to the provider — there is
no intermediary service. Prompts and answers are not logged by Notchprompt.

### Using it

1. Tap the mic (or `⌥⌘L`). The live transcript appears in the notch.
2. Ask your question out loud.
3. With **Auto-send after pause** enabled (default), the end of your sentence
   triggers the answer automatically. Disable it to send manually by tapping the
   mic a second time. **Pause before sending** is adjustable if the room is noisy
   or you talk quickly.
4. The answer appears in a card, badged with the provider that answered. It
   streams in word by word, so you can start speaking before it finishes. Use
   **Copy** to grab it, or **To script** to append it to your scrolling script.

**Repeated questions are free.** Cached answers return instantly with a green
**cached** badge and make no request. Use **Re-ask** to force a fresh one if the
cached answer was right in shape but wrong in substance.

**Continuous listening** resumes capture after each answer, so you can keep
taking follow-up questions hands-free.

**About the question filter.** With *Skip things that aren't questions* on (the
default), filler like "sounds good" is not sent to the AI — this avoids
pointless requests. If a real question does get skipped, the notch offers
**Send anyway**, and tapping the mic always sends regardless.

If no provider is configured, tapping the mic returns an error card with an
**AI Providers & Keys** shortcut to the setup panel.

## Privacy

The overlay window is created with `NSWindow.SharingType.none` and the value is
re-asserted on every show and reposition, through a KVO observer, and on a timer.
The notch is therefore excluded from `screencapture`/QuickTime, ScreenCaptureKit
and `SCStream` captures, and shared-window captures in apps such as Zoom and Meet.

This is enforced and cannot be turned off — the previous Privacy Mode toggle is
gone. It remains macOS's documented best-effort guarantee: no app can exclude its
windows from every possible capture method (for example, a camera pointed at the
screen).

API keys are stored in the Keychain. Any key saved by earlier builds is migrated
out of preferences and deleted from there on first launch.

## Build From Source

```bash
git clone https://github.com/Aarondio/notchprompt.git
cd notchprompt
open notchprompt.xcodeproj
```

CLI build:

```bash
xcodebuild -project notchprompt.xcodeproj -scheme notchprompt -configuration Debug build
```

## License

MIT. See `LICENSE`.
