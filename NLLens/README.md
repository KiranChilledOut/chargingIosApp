# NL Lens

Read Dutch apps on your iPhone in English, without leaving the app you're in.

Double-tap the back of the phone. A screenshot is taken, the Dutch is
recognised, translated, and painted back over the original layout — shown in a
sheet floating above the Dutch app. Triple-tap instead and it *explains* the
screen rather than translating it, which is what you actually want on a form.

---

## The constraint this is built around

**iOS has no floating overlays.** There is no equivalent of Android's
`SYSTEM_ALERT_WINDOW`, and no accessibility API that lets one app read another's
text. A true translate bubble hovering over another app is not possible on a
stock iPhone.

What *is* possible: an App Intent invoked from Back Tap runs in the background
and returns a snippet, which Shortcuts presents **on top of the foreground
app**. You never switch away. That is the overlay, obtained legitimately, and
it needs no screen recording, no Picture-in-Picture hack, and no app extension.

Two further constraints shaped the design:

- **Apple's OCR does not support Dutch.** It supports the Latin *script*, which
  is a different thing: the glyph recognizer reads Dutch letters fine, it's the
  language-correction pass that mangles Dutch words into English-looking ones.
  So correction is turned off, and a language model repairs the remaining noise
  using the context of the whole screen. That is why OCR repair and translation
  happen in a single prompt.
- **Vision's boxes are precise; a VLM's are not.** So geometry stays on-device
  and only *text* goes to the network. The screenshot itself is sent only for
  "explain this screen", where icons and layout carry meaning that text loses.

## How it works

```
screenshot ──▶ Vision OCR ──▶ group lines ──▶ cache lookup ──▶ hit? done, offline, free
   (device)   (device, no      into            (device)     │
               lang correction) paragraphs                  └─ miss ──▶ redact PII
                                                                          │
                                                     paint English  ◀── Nebius text model
                                                     over the boxes      (OCR repair +
                                                       (device)           translation)
```

Only the middle-right step touches the network, and only ever with text that
has been through redaction.

## Privacy

The whole point is pointing this at banking, insurance and government screens —
exactly the screens you would not paste into a third-party API. So:

- **IBAN, BSN, card numbers, email and phone are masked before the request**
  and restored in the result. Masking is checksum-validated, not just pattern
  matched: BSNs are checked with the *elfproef*, IBANs with mod-97, cards with
  Luhn. Without that, every 9-digit order number on screen would be masked and
  the translation would be useless.
- **Cache hits never touch the network at all.** After a week of normal use,
  the screens you see daily resolve locally, offline and free.
- **Cloud can be turned off entirely** in Settings, falling back to Apple's
  on-device translation. Lower quality, no OCR repair — but nothing leaves the
  phone. This runs in-app only; Apple's translation API is SwiftUI-bound and
  cannot run inside the background intent.
- The API key lives in the keychain, not in `UserDefaults` and not in source.

## Requirements

- A **Mac with Xcode 16+** (iOS 18 SDK). Non-negotiable — App Intents, Vision
  and Translation are all Apple frameworks.
- An iPhone on **iOS 18 or later**.
- A **Nebius Token Factory** API key.
- Realistically, the **$99/yr Apple Developer Program**. A free Apple ID signs
  the app for 7 days, then it stops working until you re-plug and re-sign —
  unusable for something you rely on daily. The paid account gives 1-year
  signing plus internal TestFlight.

## Build

```bash
brew install xcodegen        # once
cd NLLens
make project                 # generates NLLens.xcodeproj
open NLLens.xcodeproj
```

Then in Xcode: select your team under **Signing & Capabilities**, change the
bundle identifier to something unique to you, and run on your device.

No App Group entitlement is declared, on purpose — an unprovisioned entitlement
is the most common reason a personal build fails to sign, and the cache falls
back to Application Support without one.

Run the core test suite (no Xcode needed, works on Linux too):

```bash
swift test
```

## Set up

1. Open the app, go to **Settings**, paste your Nebius key. It goes to the
   keychain.
2. Tap **Load models from Nebius** and pick a current text model and a
   vision-capable model. Do this rather than trusting the defaults — the
   catalog changes, and a retired model id fails every request. From a
   terminal the same list is:

   ```bash
   curl -s https://api.tokenfactory.nebius.com/v1/models \
     -H "Authorization: Bearer $NEBIUS_API_KEY" | jq -r '.data[].id'
   ```

3. Verify it works **before** wiring Back Tap: on the **Screen** tab, tap the
   photo button and pick any Dutch screenshot from Photos. If that produces a
   translated overlay, the whole pipeline is good.
4. Create the shortcut: Shortcuts → new shortcut → **Take Screenshot** →
   **Translate Screen** (from NL Lens), passing the screenshot in.
5. Settings → Accessibility → Touch → **Back Tap** → **Double Tap** → your
   shortcut.
6. Optional: repeat with **Explain Screen** on **Triple Tap**.

## Using it

| Tab | What it's for |
|---|---|
| **Screen** | The last translated screen at full size. Tap any line to correct it. |
| **Write** | English → Dutch with a tone control (`u` vs `je`), copied ready to paste. |
| **Glossary** | Everything learned so far, searchable and editable. |
| **Settings** | Key, models, privacy switches. |

**Corrections are the feature worth knowing about.** Tap a wrong translation,
fix it, and it is *pinned*: it outranks the model from then on, is served
instantly and offline, and never costs a token again. Fix a bad label once
instead of re-reading it wrong forever.

## Cost

A screen is roughly 300–800 text tokens on the translate path. At typical Token
Factory pricing that is a small fraction of a cent per screen, and cache hits
are free. Ordinary daily use lands well under a dollar a month. The "explain"
path sends an image and costs more, which is why it's a separate gesture rather
than the default.

## Layout

```
NLLens/
├── Sources/NLLensCore/     # Pure Swift. No Apple frameworks. Fully tested.
│   ├── NebiusClient        # OpenAI-compatible, retry/backoff, transport seam
│   ├── Redaction           # elfproef / mod-97 / Luhn, placeholder round-trip
│   ├── JSONExtraction      # survives fences, prose padding, trailing commas
│   ├── TranslationCache    # append-only JSONL, compaction, pinned corrections
│   ├── BlockGrouping       # OCR lines → paragraphs
│   ├── LayoutFitting       # font sizing so English fits Dutch boxes
│   └── TranslationPipeline # orchestration
├── Tests/                  # 82 tests
└── App/                    # iOS-only: Vision, App Intents, SwiftUI, rendering
```

The split is deliberate: everything that doesn't need an Apple framework lives
in a package that compiles and tests without Xcode, which is most of the logic
that can actually be wrong.

## Verification status

Be aware of what has and hasn't been checked:

- **`NLLensCore` — verified.** 82 tests pass on Swift 6.1. Covers the redaction
  checksums, the placeholder round-trip, malformed-model-output parsing, cache
  persistence and compaction, the coordinate flip, layout maths, and pipeline
  behaviour against a mock transport (missing ids, duplicate ids, cache hits,
  batching, cloud-off).
- **`App/` — written but never compiled.** It was developed on Linux, where no
  iOS SDK exists. Every file parses cleanly and has been reviewed by hand, but
  it has not been through a type-checker and has never run on a device. Expect
  to fix some compile errors on first build — most likely candidates are App
  Intents API details and iOS 18 `TranslationSession` specifics, which change
  between SDK versions.
- **No live Nebius call has been made.** The client is tested against a mock.
  The default model ids are plausible but unconfirmed; use the model picker.
