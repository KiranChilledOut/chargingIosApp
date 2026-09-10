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
