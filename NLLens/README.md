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

Model output is constrained with Nebius's `response_format` JSON Schema
support, which is a much stronger guarantee than asking for JSON in the
prompt. Not every hosted model implements it, so a rejected request is retried
once without the constraint, and a forgiving parser (markdown fences, prose
padding, trailing commas) backs both paths up.

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

## Install on your iPhone

`NLLens.xcodeproj` is committed, so there is nothing to generate and no
Homebrew needed.

```bash
git clone https://github.com/KiranChilledOut/chargingIosApp.git
cd chargingIosApp
git checkout claude/ios-translation-overlay-dzyv4v
open NLLens/NLLens.xcodeproj
```

In Xcode, select the **NLLens** target → **Signing & Capabilities**:

1. Tick **Automatically manage signing**.
2. **Team** → your Personal Team. Not listed? Xcode → Settings → Accounts → **+**.
3. **Change the bundle identifier.** `com.nllens.app` is taken; it must be
   globally unique. Something like `com.yourname.nllens`.

Plug the iPhone in, pick it as the run destination, press **⌘R**.

First launch refuses with "Untrusted Developer". On the phone: **Settings →
General → VPN & Device Management → [your Apple ID] → Trust**, then launch
again.

A **free Apple ID** is enough for testing, with two limits: the signature
expires after **7 days** (plug in, ⌘R again to renew — the app stays installed
but won't open until you do), and you can have three sideloaded apps at once.
The $99/yr account removes both and is worth it once you find you use this
daily.

No App Group entitlement is declared, on purpose — an unprovisioned entitlement
is the most common reason a personal build fails to sign, and the cache falls
back to Application Support without one.

If you edit `project.yml` or add files, regenerate with
`brew install xcodegen && make project`.

Run the core test suite (no Xcode needed, works on Linux too):

```bash
swift test
```

## Set up

1. Open the app, go to **Settings**, paste your Nebius key. It goes to the
   keychain, which survives both app updates and the weekly re-signing.
2. Tap **Load models from Nebius** and pick a current text model and a
   vision-capable model. Do this rather than trusting the defaults — the
   catalog changes, and a retired model id fails every request. From a
   terminal the same list is:

   ```bash
   curl -s https://api.tokenfactory.nebius.com/v1/models \
     -H "Authorization: Bearer $NEBIUS_API_KEY" | jq -r '.data[].id'
   ```

3. Verify it works **before** wiring Back Tap. Two checks, in order:

   ```bash
   NEBIUS_API_KEY=... make smoke      # key, model id, and JSON output
   ```

   then in the app, on the **Screen** tab, tap the photo button and pick any
   Dutch screenshot from Photos. If that produces a translated overlay, the
   whole pipeline is good. Doing it in this order tells you whether a failure
   is your key, your model choice, or the app.
4. **The zero-setup way — try this first.** Take a screenshot, tap the
   thumbnail, hit **Share**, choose **NL Lens**. That's it: no Shortcuts
   recipe, no Back Tap, nothing to configure. Share several screenshots at
   once and they're stitched into one document automatically.

   Back Tap is faster once configured, and worth setting up if you use this
   daily — but the share sheet works the moment you install.

5. For Back Tap: Shortcuts → new shortcut → **Take Screenshot** →
   then one of these NL Lens actions, passing the screenshot in:

   | Action | What you get | Best for |
   |---|---|---|
   | **Translate Screen** | NL Lens opens and draws the translated screen edge to edge. | Almost everything |
   | **Translate Long Screen** | Several captures joined into one continuous English document. | Articles, terms, emails — anything longer than a screen |

   *(**Translate Screen (Full Size)** also appears, and does exactly the same
   thing as **Translate Screen**. It only exists so shortcuts built before the
   default changed keep working — either is fine.)*

   Translating brings NL Lens forward for a moment. That is the trade for
   filling the display: a Shortcuts snippet stays over the Dutch app but is a
   system-sized card with a Done button, and cannot be made full screen no
   matter how its contents are laid out. Since the rendered image has exactly
   the dimensions of the screen it came from, drawn full-bleed it reads as your
   screen with English on it.

   **For long screens**, build the shortcut as: **Get Latest Screenshots**
   (count: however many you took) → **Reverse** (so they run oldest first) →
   **Translate Long Screen**. Scroll through the Dutch content taking
   screenshots as you go — overlapping deliberately so you miss nothing — then
   run it once. Repeated lines in the overlap are detected and merged, and
   cost nothing to translate twice because the cache already has them.

   The screenshot has to come from the Shortcuts action rather than from the
   app, because no app can capture another app's screen — Shortcuts holds that
   privilege and NL Lens does not. That is why this one manual step exists.
6. Settings → Accessibility → Touch → **Back Tap** → **Double Tap** → your
   shortcut.

## Using it

| Tab | What it's for |
|---|---|
| **Screen** | The last translated screen, with every line correctable. |
| **History** | Every screen you've translated, searchable in English. |
| **Write** | English → Dutch with a tone control (`u` vs `je`), copied ready to paste. |
| **Glossary** | Everything learned so far, searchable and editable. |
| **Settings** | Key, models, privacy switches. |

In the full-size viewer: **hold anywhere** to peek at the original Dutch,
pinch or double-tap to zoom, swipe down to dismiss.

It has three modes, picked from the control top-right:

- **Screen** — English drawn over the original layout. Right when which label
  belongs to which button is the point.
- **Text** — the same translation reflowed as real text: selectable, honours
  Dynamic Type, scrolls past the bottom of the capture, and copies out whole.
  Right for prose. Headings are recovered from how tall each line was on
  screen, so a long page keeps its structure instead of becoming a wall.
- **Ask** — a conversation about the screen. If the answer depends on your
  situation it asks first: *"do you rent or own?"* — then commits to an answer
  and quotes the Dutch it rests on. A one-shot explanation can say what a
  checkbox is about; it can't say whether to tick it.
- **Explain** — what the screen is *asking*, rather than what it says. Which
  field wants your BSN, which box is pre-ticked, what renews monthly, what the
  deadline is. Warnings come before steps, because the point is to see the cost
  before you start following the instructions that commit you to it.

Stitched long-screen documents open in Text mode, because their layout comes
from several different captures.

Explain is the thing a free translator can't do, and it costs a vision call, so
it only runs when you actually open that tab.

**Corrections are the feature worth knowing about.** Tap a wrong translation,
fix it, and it is *pinned*: it outranks the model from then on, is served
instantly and offline, and never costs a token again. Fix a bad label once
instead of re-reading it wrong forever.

## What it knows that a translator doesn't

Dutch bureaucratic terms translate into English that's correct and useless:

| Dutch | Literal | What you're actually told |
|---|---|---|
| *eigen risico* | "own risk" | Your insurance deductible — the fixed yearly amount you pay before cover starts |
| *loonheffingskorting* | "payroll tax credit" | Apply it at **one** employer only; two is why people owe tax back |
| *WOZ-waarde* | "WOZ value" | The council's valuation of your home, which several taxes are based on |

Forty terms across tax, benefits, health, housing, banking, work and identity,
matched against the Dutch on screen and fed to the model before it answers.
Amounts are deliberately absent — they change yearly, and a stale number is
worse than none.

## Scam checking

Someone who can't read a language also can't hear when its register is wrong,
which is how native speakers spot phishing in a second. Captured screens are
checked for password requests, manufactured urgency, mismatched web addresses
and payment redirection, and a banner appears **only when something looks
wrong**. An ordinary screen says nothing — a badge on every screen is one
nobody reads.

Turn it off in Settings if you'd rather not spend the extra request.

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

- **`NLLensCore` — verified.** 96 tests pass on Swift 6.1, no warnings.
  Covers the redaction checksums, the placeholder round-trip,
  malformed-model-output parsing, cache persistence and compaction, the
  coordinate flip, layout maths, the exact request wire shape, and pipeline
  behaviour against a mock transport (missing ids, duplicate ids, cache hits,
  batching, cloud-off).
- **`App/` — written but never compiled.** It was developed on Linux, where no
  iOS SDK exists. Every file parses cleanly and has been reviewed by hand, but
  it has not been through a type-checker and has never run on a device. Expect
  to fix some compile errors on first build — most likely candidates are App
  Intents API details and iOS 18 `TranslationSession` specifics, which change
  between SDK versions.
- **Endpoint verified live; no authenticated call made.** Both
  `/v1/models` and `/v1/chat/completions` were probed unauthenticated and
  return 401, confirming the base URL and paths are right. Two things were
  corrected as a result:
  - Nebius returns errors as `{"detail": "..."}`, **not** the OpenAI
    `{"error":{"message":...}}` shape. Reading only the OpenAI shape left
    every failure with a blank reason — exactly when you most need it.
  - Nebius puts a JSON Schema **directly** under `json_schema`, not inside
    OpenAI's newer `{name, strict, schema}` wrapper.

  No request with a real key has been made, so model behaviour and token
  costs are unmeasured. **The default model ids are plausible but
  unconfirmed** — use the in-app model picker.
