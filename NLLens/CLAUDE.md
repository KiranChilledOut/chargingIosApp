# NL Lens — working context

An iOS app that translates Dutch app screens to English. Read `README.md` for
what it does and how it is set up; this file is about working on the code.

## Immediate state

**`Sources/NLLensCore` is verified. `App/` has never been compiled.**

The whole thing was written in a Linux container with no iOS SDK. The core is
a plain Swift package, so it was compiled and tested there (96 tests, no
warnings). Everything under `App/` — Vision, App Intents, SwiftUI, UIKit —
could only be parsed and hand-audited. It has never been through a
type-checker and has never run on a device.

**So the first job on a Mac is getting `App/` to compile.** Expect real errors.
That is anticipated, not a sign something is deeply wrong.

## Verify

Compile the app without needing a device, a team, or signing:

```bash
xcodebuild -project NLLens.xcodeproj -scheme NLLens \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

That is the fastest loop for shaking out compile errors — use it, not a device
build, until it passes. Then:

```bash
swift test    # core, 96 tests, must stay green
```

Only after both pass is a device build worth attempting.

## Where errors are most likely

In rough order of probability:

1. **App Intents.** `IntentFile.data` access, `@Parameter` with
   `supportedContentTypes`, `AppShortcutsProvider` phrase syntax, and
   `IntentDescription(_:categoryName:)`. These shift between SDK versions.
2. **`OnDeviceTranslation.swift`** — the iOS 18 `TranslationSession` batch API
   (`TranslationSession.Request`, `session.translate(batch:)`,
   `response.clientIdentifier`). Least certain code in the project.
3. **SwiftUI availability/API drift** in the four views.

## Things that look like bugs but are not

Do not "correct" these — each was verified against the live Nebius API and
each has a test pinning it:

- **Nebius returns errors as `{"detail": "..."}`**, not OpenAI's
  `{"error": {"message": ...}}`. `NebiusClient.errorMessage(from:)` reads
  `detail` first on purpose. Changing it to the OpenAI shape makes every
  failure show a blank reason.
- **A JSON Schema goes directly under `json_schema`**, not inside OpenAI's
  newer `{name, strict, schema}` wrapper. See `WireShapeTests`.
- **`usesLanguageCorrection = false` with `recognitionLanguages = ["en-US"]`**
  in `VisionOCR`. Vision does not support Dutch. The glyph recognizer handles
  Latin script fine; it is the language-correction pass that mangles Dutch
  words. The LLM repairs the remaining noise. Turning correction back on makes
  output worse, not better.
- **No App Group entitlement.** Deliberate — an unprovisioned entitlement is
  the most common reason a personal build fails to sign, and the cache falls
  back to Application Support without one. Do not add one unless an extension
  actually needs shared storage.
- **`NLLensSnippetView` is one type with a `Content` enum** rather than four
  view structs. App Intents declare their snippet as an opaque `some View`, so
  every branch of `perform()` must return the *same* concrete type. Splitting
  it back into separate views will not compile.

## Two presentation modes

`TranslateScreenshotIntent` (`openAppWhenRun = false`) returns a Shortcuts
snippet and never leaves the Dutch app. `TranslateFullScreenIntent`
(`openAppWhenRun = true`) brings the app forward and hands the result to
`OverlayViewerView` via `OverlayPresenter`.

Both exist because a snippet **cannot** be made full screen — it is a
system-sized sheet, and capping or uncapping its contents does not change
that. Do not try to "fix" the card by making it bigger; the full-size path is
the answer, and the cost is that the app comes forward.

`OverlayPresenter` is deliberately not a `@MainActor` type — that would make
reading `.shared` from a `View` property initializer an isolation question.
Its mutating methods carry the isolation instead.

## Reading mode and stitching

`OverlayViewerView` has two modes. Image mode draws the rendered overlay;
reading mode (`ReadingModeView`) reflows the same blocks as text. Neither is
the default everywhere — a screen of controls needs the overlay, a screen of
prose needs text — so multi-capture documents open in reading mode and single
captures in image mode.

`ScreenStitching` joins captures taken while scrolling. Consecutive captures
overlap because people scroll less than a full screen on purpose; it finds the
longest run where the end of one matches the start of the next and drops the
repeat. **Bounding boxes in a stitched document are not in one coordinate
space** — each was normalized against its own capture — so a stitched document
must never be handed to `OverlayRenderer`. `Snapshot.isMultiScreen` is the
guard.

`TypographyHints` recovers headings from box height relative to the document
median, because the recognizer reports no font size and reading mode would
otherwise flatten every long page into undifferentiated text. The ratios are
relative on purpose: absolute heights vary with device and capture scale.

## Capture paths

Three ways in, deliberately:

- **Share sheet** — `CFBundleDocumentTypes` declares the app an image viewer,
  so it appears in the share sheet; `IncomingImageCoordinator` handles the
  `onOpenURL`. Zero setup, which makes it the right first experience. It is
  **not** a share extension on purpose: an extension needs an App Group, and
  App Groups need a paid developer account.
- **Back Tap → Shortcuts → App Intent** — fastest, but needs configuring.
- **In-app Photos picker** — for testing and for screenshots already taken.

Multiple shared images are coalesced over a 400 ms window before processing.
Without that, three shared screenshots start three translations that each
overwrite the last, instead of one stitched document.

Both foregrounding intents raise a progress indicator *before* doing any work.
`openAppWhenRun` brings the app forward first, so without it the app shows a
blank tab for the seconds the translation takes — which reads as a Back Tap
that never registered, and gets tapped again. Every early return in those
intents must clear it.

## Explanations decode leniently

`ScreenExplanation` has a hand-written `init(from:)` because vision models
drift from the requested schema far more than text models do: a lone action
arrives as a bare string, lists arrive as objects with a `text` key, empty
sections are omitted rather than sent as `[]`. Synthesized decoding throws on
all of those and the user sees an error for a usable reply. `encode(to:)` is
explicit because the alternate-spelling `CodingKeys` cases stop Swift
synthesizing one.

## Conventions

- The API key lives in the keychain only. Never add a build setting, an
  xcconfig, or a default that puts a key in a file in the repo.
- `Sources/NLLensCore` must not import any Apple framework beyond Foundation —
  that is what keeps it testable off-device. Anything needing UIKit, Vision,
  SwiftUI or AppIntents belongs in `App/`.
- New logic that can live in Core should, because Core is the only half that
  can be tested without a device.
- `project.yml` is the source of truth for the Xcode project;
  `NLLens.xcodeproj` is generated and committed. After changing `project.yml`
  or adding files: `brew install xcodegen && make project`.
- Adding a file under `App/` requires regenerating the project, or Xcode will
  not see it.

## Testing the cloud half

`NEBIUS_API_KEY=... make smoke` checks the key, the model id, and that a
redaction placeholder survives a round trip — without building anything.
Useful for telling "my model id is wrong" apart from "the app is broken".

## Repository note

This repo's root is an unrelated Expo/React Native battery app. **Do not touch
anything outside `NLLens/`.** Work happens on the branch
`claude/ios-translation-overlay-dzyv4v`.
