# Notchprompt — Implementation Plan

Status: **Draft** · Last updated: 2026-09-29 · Target: `notchprompt` 1.2.0+

This plan covers the roadmap for turning Notchprompt from a teleprompter with a
voice feature into a tool that reliably answers questions *in about two
seconds, while someone is waiting for you to speak*.

---

## 1. The governing constraint

Every change is judged against one question:

> **Can the user get a good answer out loud before the other person loses patience?**

That single constraint drives all sequencing. It is why streaming beats a
prettier settings screen, and why "jump to the right line" beats "append the
answer to the end of the script."

## 2. Goals and non-goals

### Goals

- Cut perceived answer latency below ~1 second to first word.
- Stop wasting tokens on things that are not questions.
- Make answers *specific to where the speaker currently is*, not generic.
- Make recall instant for questions that repeat across sessions.
- Close the foundational gaps that currently break for real users.

### Non-goals (explicitly out of scope)

Text-to-speech, practice mode with recording, and cloud sync. All are real
work, none of them serve the two-second promise, and each dilutes it.

---

## 3. Primary use cases

### 3.1 Sales — **primary**

The target workflow is a live call: outbound, discovery, demo, or negotiation.
The script is the rep's playbook, which naturally has stages:

```
Opener → Qualify → Pitch → Demo → Pricing → Objection handling → Close
```

How each planned feature serves it:

| Feature | Value in a sales call |
|---|---|
| **Streaming** | The prospect says "can you send me an email?" — you need the first words in under a second, not two seconds of dead air. |
| **Question gate** | Sales calls are ~40% small talk and rapport-building. Without a gate, every "sounds good, let me pull that up" becomes a billable API call. |
| **Answer cache** | Objections repeat relentlessly across calls: *too expensive, we already use a competitor, it's not in budget, send me info.* These should be instant and free. |
| **Position-aware context** | Knowing the rep is at the *pricing* stage makes the answer to "is there a discount?" far better than a generic response from a script read top-to-bottom. |
| **Jump to the relevant line** | Instantly land on the right objection response instead of scrolling to find it — this is the single most valuable feature for a rep. |
| **Recall / history** | A question flashes by, you miss it, and you need it back five seconds later. |
| **Call notes for free** | The Q&A history *is* a structured record of what the prospect asked. High value, essentially free. |

### 3.2 Secondary

- **Interviews** — "tell me about yourself", "greatest weakness". Cache and speed matter most.
- **Live teaching / lectures** — position-aware context and jump-to-line matter most.
- **Streaming / content recording** — script structure and pacing matter most.

> **Design rule:** if a change helps one of these but hurts the two-second
> promise, the promise wins.

---

## 4. Architecture prerequisite

### [ ] Phase 0 — Extract `ScriptPositionModel`

**Why this is first:** two of the best features (position-aware context,
jump-to-line) are impossible until the model layer can *read* where the
teleprompter is and *command* it to move. Today that state is trapped in
private `@State` inside `ScrollingTextView`, and the only view→model channel is
write-only UUID command tokens.

**What changes**

- New `ScriptPositionModel` (`@MainActor`, `ObservableObject`) publishing
  `phase`, `contentHeight`, `viewportHeight`, `progress` (0–1), and a
  `seek(toPhase:)` command with a `seekToken`.
- `ScrollingTextView` writes its tick state into it rather than owning it
  exclusively, and observes `seekToken` to move.
- Supersedes the ad-hoc `onSaveScrollPhaseForResume` closure.

**Files:** `notchprompt/ScriptPositionModel.swift` (new),
`notchprompt/ScrollingTextView.swift`, `notchprompt/PrompterModel.swift`,
`notchprompt/OverlayView.swift`

**Risk:** Low · **Effort:** ~1 day · **Blocks:** Phases 4 and 5

---

## 5. Phases

### [ ] Phase 1 — Stream answers token-by-token

**Goal:** first visible word in ~400ms instead of after the full response.

`AIChatCompletionRequest` already carries a `stream` field that is hardcoded
`false`. This is mostly plumbing.

- `AIService`: add `answer(question:context:onDelta:)` over
  `URLSession.bytes(for:)` with SSE frame parsing (`data:` lines terminated by
  `[DONE]`).
- **Reasoning models:** `deepseek-reasoner` emits `reasoning_content` deltas
  before the answer. Route these to the existing "Thinking…" state. If these
  leak into the visible answer, users watch raw reasoning tokens scroll past.
- Fall back to non-streaming if a provider rejects `stream: true`.
- `ListenState` gains partial-answer rendering.

**Files:** `AIService.swift`, `ListenModel.swift`, `OverlayView.swift`

**Risk:** Medium (async byte streams, actor hops) · **Effort:** ~1 day

---

### [ ] Phase 2 — Question gate and tunable silence

**Goal:** stop paying for things that are not questions.

Today any speech followed by ~1.4s of silence becomes a billable request.

- `QuestionGate` — pure, trivially testable. Send if the utterance ends in `?`,
  begins interrogatively, or exceeds a word threshold. **Default permissive**;
  never silently swallow a real question.
- Settings: silence-threshold slider (replaces the hardcoded `1.4`), gate toggle,
  word threshold.
- **Send anyway** escape hatch on the error card.

**Files:** `QuestionGate.swift` (new), `SpeechRecognizerService.swift`,
`ListenModel.swift`, `ContentView.swift`

**Risk:** Low · **Effort:** ~0.5 day · **Pays for itself immediately**

---

### [ ] Phase 3 — Answer cache

- `AnswerCache` actor keyed on a normalized question (lowercase, strip
  punctuation, collapse whitespace). LRU eviction, TTL, size cap.
- In-memory by default. **Optional disk persistence behind an explicit toggle** —
  a disk cache stores answers on disk, which cuts against the app's privacy
  story. It should be opt-in and clearable.
- UI: "cached" badge plus a **Refresh** action to bypass.

**Files:** `AnswerCache.swift` (new), `AIService.swift`, `ListenModel.swift`

**Risk:** Low · **Effort:** ~0.5 day

---

### [ ] Phase 4 — Position-aware context

**Goal:** answers that are relevant to *this part* of the talk.

Today the model receives the first 6,000 characters of the script, which amounts
to "here is my whole talk." Instead send:

- `progress` (percentage through the script)
- the current section heading, if present
- a ±N character window around the cursor

Prompt template becomes: *"The speaker is 34% through a talk about X. Current
section: '…'. Answer the question in that context."*

Ship without heading parsing first; structured sections are a later refinement.

**Files:** `AIService.swift`, `ScriptPositionModel.swift`, `PrompterModel.swift`

**Risk:** Low · **Effort:** ~1 day · **Depends on:** Phase 0

---

### [ ] Phase 5 — Jump to the relevant script line ⚠️ SPIKE FIRST

**The riskiest item in the plan.** Mapping a string range to a rendered y-offset
inside a SwiftUI `Text` is genuinely fiddly: it has to account for line wrapping,
font metrics, and dynamic type.

- **Step 1 — spike (~0.5 day).** Prove you can locate a quote in the script and
  scroll to it. If the text-offset math is not clean, **stop here.** Phase 4
  delivers most of the value at a fraction of the cost.
- **Step 2 — structured responses.** Ask for `{answer, script_quote}` via
  `response_format: json_object`. ⚠️ Not universally supported (Together notably)
  — must degrade cleanly to plain text.
- **Step 3 — navigate.** Seek to the match, highlight it, and replace the
  append-to-the-end **To script** behavior with inline placement near the
  current position.

**Files:** `ScrollingTextView.swift`, `AIService.swift`, `OverlayView.swift`

**Risk:** High · **Effort:** 2–3 days *if the spike passes*

---

### [ ] Phase 6 — Recall answers in the notch

History exists in `ListenModel` but only renders in Settings. Add a strip to the
notch answer card to page through recent Q&A and re-copy, covering the "question
flashed by" moment.

**Files:** `OverlayView.swift`, `ListenModel.swift`

**Risk:** Low · **Effort:** ~0.5 day

---

### [ ] Phase 7 — Foundational gaps

- [ ] **Script library.** `ScriptFileIO` handles a single file. Named saved
      scripts with a picker and recents. High value, unrelated to AI.
- [ ] **Speech locale picker.** `defaultLocaleIdentifier = "en-US"` is hardcoded
      and `startListening(localeIdentifier:)` is *never called with an argument*.
      **Listen is currently broken for any non-English speaker.** Highest
      severity item in this phase for the cost of the fix.
- [ ] **First-run onboarding.** A new user's first experience today is tapping
      the mic and getting a red error card.
- [ ] **Token / cost meter.** Parse `usage` from responses and surface spend.

**Files:** `ScriptFileIO.swift`, `ScriptLibrary.swift` (new),
`SpeechRecognizerService.swift`, `ContentView.swift`, `AIService.swift`

**Risk:** Low each · **Effort:** ~1 day total

---

## 6. Cross-cutting requirements

These apply to **every** phase. They are not a phase.

### 🔴 Capture-exclusion audit — the easiest thing to forget

`sharingType = .none` is currently set on the **overlay panel only**
(`OverlayWindowController.swift:95`). Any new window — an onboarding sheet, an
answer detail popover, a provider picker — is **screen-recordable by default**
and would silently break the app's headline privacy promise.

> **Requirement:** every new window or sheet must set `.none` and be verified.
> Add a check to the startup self-tests that enumerates app windows and asserts
> `sharingState == 0`.

### Tests

The repo has `ScreenSelectionSelfTests.swift` and DEBUG self-check patterns. Add
equivalents for every piece of pure logic introduced:

- question gate
- cache-key normalization
- SSE frame parsing
- scroll position / offset math
- locale matching

A real test target is a worthwhile follow-up.

### Feature flags

Any behavior change ships behind a flag defaulting to current behavior, so
existing users are not disrupted mid-call.

### Cost instrumentation

Track token usage from the first AI change onward. A sales rep on a metered
plan needs to see cost.

---

## 7. Milestones

| # | Scope | Ships | Effort |
| --- | --- | --- | --- |
| 1 | Phase 0 → 1 → 2 | **Feels instant, costs less** | ~2.5 days |
| 2 | Phase 4 (+3 if time) | **Answers that know where you are** | ~1.5 days |
| 3 | Phase 5 *(only if spike passes)* | Navigate, don't just read | 2–3 days |
| 4 | Phase 6 → 7 | Polish and close real gaps | ~1.5 days |

**Milestone 1 is the one to start.** It contains the two changes users notice
most and the highest rate limit is lowest.

---

## 8. Open decisions

- [ ] **Primary audience weighting.** Sales is treated as primary here. Confirm
      whether interviews or teaching should change the ordering.
- [ ] **Cache persistence on disk** — opt-in (recommended) or in-memory only.
- [ ] **Script library storage** — UserDefaults, a documents folder, or Core Data.
- [ ] **Version target.** This plan is scoped for 1.2.0; `MARKETING_VERSION` is
      currently 1.1.3 and `CHANGELOG.md` has no entries after 1.1.1.

---

## 9. Recently shipped (context)

For reference, the following already landed and are the baseline this plan
builds on:

- Listen mode: mic → transcription → AI answer rendered in the notch.
- Provider picker (OpenAI, DeepSeek, Groq, OpenRouter, Together, custom) with
  key entry inside the notch.
- Automatic fallback provider on rate limit, 5xx, network, or auth failure.
- API keys in the Keychain, migrated out of preferences.
- Enforced `NSWindow.SharingType.none` capture exclusion.
