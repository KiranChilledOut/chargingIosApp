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

## All translate actions open the app

"Translate Screen", "Translate Screen (Full Size)" and "Translate Long Screen"
all set `openAppWhenRun = true` and present `OverlayViewerView`. The first two
are deliberate duplicates sharing `FullScreenTranslationRun`: renaming or
removing an action breaks any shortcut already bound to it, and a shortcut that
silently stops working is worse than a spare row in the Shortcuts picker.

"Translate Screen" used to return a Shortcuts snippet, so that the Dutch app
was never left. Do not restore that: a snippet is a system-sized card with a
Done button and **cannot** fill the display, so the most obviously-named action
was quietly giving the worst presentation. Snippets remain right for Explain
and Write in Dutch, which are short answers rather than a screen to read.

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

## The full-bleed image is deliberate, not redundant

`OverlayViewerView.imageLayer` reads bounds from a `GeometryReader` that
ignores the safe area and frames the image to them explicitly. That looks like
something a tidy-up would replace with a plain `.scaledToFit()`. It is not.

`scaledToFit` sizes to the *proposed* size, and inside a presented cover the
proposal is already inset by the safe area — so the capture lands in about 759
of the 852 points an iPhone 14 Pro has, with black bands top and bottom.
`.ignoresSafeArea()` applied afterwards extends where the view may draw but
never re-proposes a larger size, so it does not fix it.

The whole point of image mode is that it reads as the screen you were just on.
Letterboxing breaks that, so: explicit frame, `scaledToFill`, and chrome that
fades after a moment rather than parking on top of the picture.

## Losing content is the failure that matters

It is silent: a reader cannot tell a dropped sentence from one that was never
on screen. Four things guard against it, and none should be tightened without
a reason better than tidiness.

- **`VisionOCR.minimumConfidence` is 0.** Language correction is off because
  it mangles Dutch, so the recognizer reads Dutch with no lexicon behind it and
  reports low confidence for text it got *right*. A 0.3 floor was silently
  discarding correct Dutch before the model saw it. The model repairs noise; it
  cannot recover a line that never arrived.
- **Groups are capped** in lines and characters. Uncapped, a page of prose
  merges into one block, rides on one translation unit, and a model handed one
  very long string paraphrases rather than renders it.
- **`batchSize` is 20, not 40.** The output is the binding constraint — every
  run returns repaired Dutch *and* English — so a large batch truncates
  mid-array and the request is wasted.
- **Omitted ids are re-requested once.** Models drop entries from long lists.
  Without the retry those runs render as untranslated Dutch.

`CompletenessTests` and `BlockGroupingCapTests` pin all of this.

## The app is built on a design system

`App/Design/Theme.swift` holds spacing, radii, palette, type and motion. Views
draw from it rather than reaching for literals — a view with a bare `16` in it
is one that will drift. `LabeledSection`, `cardSurface`, `pill` and
`floatingControl` are the shared building blocks; prefer them to re-rolling the
same padding-and-material stack.

Note `LabeledSection` is not called `Section`: SwiftUI has one, used throughout
`Form` and `List`, and a same-named type in this module shadows it everywhere.

## Chat, terms, risk and the archive

- `ScreenConversation` keeps the screen in the **system message**, never the
  turns. A vision model reads the screenshot once; every turn after is
  text-only. Do not "simplify" this by re-sending the image per turn.
- `DutchTermIndex` matches on **word runs, not substrings** — Dutch compounds
  put "borg" inside "borgstelling". Meanings carry no amounts: they change
  yearly, and `testMeaningsCarryNoHardCodedAmounts` enforces it.
- `RiskAssessment.Level.parse` resolves unknown words to `.caution`, never
  `.fine`. An unrecognised answer is not evidence of safety. A failed check
  shows nothing rather than implying the screen is clean.
- Chat redacts the screen text, the visual reading and every message under one
  shared namespace, so one IBAN is one placeholder rather than two accounts.
- The archive files a screen on **arrival** in the viewer, not on exit, so it
  survives the app being killed mid-read. Reopening from History passes
  `archivable: false` so revisiting does not file a duplicate. Its encoder and
  decoder both use `.iso8601` — mismatched strategies write fine and read back
  empty.

## Overlay rendering has three traps

All three were found by comparing a rendered screen against the original, not
by reading the code.

- **Never truncate.** `LayoutFitting` approximates character width, and the
  real font is usually wider, so its answer overflows the box. With a
  truncating paragraph style that came out as "…" and the reader lost the end
  of a sentence without being able to tell. `draw` now takes the estimate as an
  upper bound and shrinks against real `boundingRect` measurement, wraps rather
  than truncates, and allows a modest overflow before clipping.
- **Dominant colour, not mean.** A bright green header with black lettering
  averages to murky dark green, so the fill reads as a stain and the contrast
  rule then puts white text on it. Background pixels outnumber glyph pixels, so
  the modal bucket of a small sampled grid is the background.
- **Grouping steps over asides.** A block that does not belong used to close
  the group. An icon in the margin, sitting vertically between two lines of a
  wrapped date, therefore split it — and the second line stayed on screen
  untranslated beside its own translation. Narrow, off-column blocks are now
  set aside and kept as their own block; a wide one still starts a new group.

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
