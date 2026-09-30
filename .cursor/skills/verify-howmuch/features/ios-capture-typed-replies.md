# iOS capture typed replies

Conversational **Add Transactions** types a short British waiting line while a reply is in flight, then types the finished helper text once the model returns a complete reply. Failed and stopped replies dump in full immediately. Spec: `docs/frontend/intake-ui.md`. Lives on PR [#153](https://github.com/yjsoon/howmuch/pull/153) (`cursor/capture-rename-payee-a557`, commit `29f42e7`). Not on `cursor/ios-build-4-8d47`.

## Sub-features

- `typed-wait` types cycling waiting copy (for example **One tick.**) while the reply is in flight. VoiceOver is **Working on a reply.** Not the old frozen **Let me take a look…**. Already proven on Simulator; do not redo unless that phrase is back.
- `typed-reply-complete` types the finished assistant text character by character after a successful parse, then shows the Lunch $12 (or equivalent) draft card. Proven on Simulator with OpenRouter GPT 5.6 Luna (`mid-complete.png` / `finished-complete.png`).
- `typed-reply-failed-dumps` shows a failed reply in full immediately, with no typewriter. Already observed when on-device Foundation Models returned `GenerationError error -1`.
- `typed-reply-reduce-motion` shows the current waiting line in full when Reduce Motion is on. Covered by `CaptureAssistantPresenceTests`; skip on Simulator unless that test is missing.

## How to get to it (user POV)

- Tap the floating **Assistant** (speech bubble with a plus) above Add, then start a conversation.
- Type a spend in the composer and choose **Send**.
- Trailing sparkles **AI provider** on the Add Transactions toolbar (not Connection) chooses on-device vs a remote model.

## Driving it with control-howmuch

Preconditions:

- Darwin + Xcode. Linux cannot run this recipe. Target **howmuch-mac** / `yjmbpro.local`.
- Checkout `cursor/capture-rename-payee-a557` at `29f42e7` or this stacked branch. `CaptureAssistantPresence.swift` and `CaptureAssistantPresenceTests` must exist.
- `control-howmuch doctor` passes against an isolated verify stack. Reuse a healthy instance; do not point the app at production (`howmuch.tk.sg` or the legacy `howmuch.soon.sg`).
- [iOS connection](./ios-connection.md) signed in as `verifier`. Server is `{api_url}` (`http://127.0.0.1:{api_port}`). After Sign in, tap trailing **Save** on Connection (axe does not expose that toolbar button; on iPhone ~360,105).
- Pin an explicit Simulator UDID. Never `simctl io booted`. On `yjmbpro`, use HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5). Leave other xcodebuild jobs (including ICPhoto) alone. Do not set `HOWMUCH_SHUTDOWN_OTHER_SIMULATORS=1`.
- Rebuild before test/install. `scripts/ios-xcodebuild.sh test` runs `build-for-testing` first on every run and stops if it fails. Do not use `test-without-building` here; it reruns the previous bundle. Required:

```
SIMULATOR_UDID=<udid> scripts/ios-xcodebuild.sh test -- -only-testing:HowMuchTests/CaptureAssistantPresenceTests
```

Then `simctl install` that `app-path` onto the same UDID and `simctl launch … sg.soon.howmuch`.

- On-device Apple Intelligence on that Verification Simulator is a **dead end** (`FoundationModels.LanguageModelSession.GenerationError error -1`). Do not retry on-device there.
- A working **remote** capture model is required to re-drive `typed-reply-complete`. Connection stays on the verify API. In Add Transactions, open **AI provider**, pick a provider, paste an API key supplied by the operator, Save AI settings. There is no key in this repo. Unsigned `CODE_SIGNING_ALLOWED=NO` builds cannot store the key. Financial text is sendable as soon as a provider and key are saved; there is no consent switch. Do not invent a key. Do not use production HowMuch.

- **Do not redo waiting.** `typed-wait` already passed. Stills: `artifacts/ios-capture-typewriter/mid-type.png`.
- **Do not redo complete** unless the finished-reply typewriter is gone. Proven stills: `artifacts/ios-capture-typed-replies/mid-complete.png` (prefix plus cursor) and `finished-complete.png` (full reply + Lunch −$12.00 draft).
- **Fail closed.** If the bubble is `I could not read that` / `GenerationError`, that is `typed-reply-failed-dumps`, not a pass for `typed-reply-complete`.
- **Proof.** Stills + notes under `artifacts/ios-capture-typed-replies/`. Do **not** commit the session mp4.

## Gotchas

- This is the conversational sheet titled **Add Transactions**, not the manual **Add Transaction** form and not web `/add`.
- Animate the finished text only when the reply just reached complete. History must not replay the typewriter. Failed/stopped copy dumps in full.
- A stale-bundle 0-test run happened when `test` skipped the rebuild whenever products existed (#166). `test` now always rebuilds; check for `runner: build-for-testing succeeded` before trusting a result.
- Three simulators were booted on `yjmbpro`. `simctl io booted` captures the wrong device.
- Last known healthy stack (reuse if doctor still says ok; otherwise `launch` a new one): session `howmuch-verify-20260908T084259-43409`, API `http://127.0.0.1:60500`, web `http://127.0.0.1:60501`, `verifier` / `howmuch-verify-15`, plan `local-plan` / HowMuch Demo.
- Drive with axe (`describe-ui` / `tap` / `type`) and `--udid` the pinned Verification UDID. Prior helper: `/tmp/howmuch-typed-replies/axe_drive.py`.
- Unsigned `scripts/ios-xcodebuild.sh` products cannot store AI keys. Sign a Simulator Debug build if you need a remote provider.
- No product-code change was needed. A `.complete` UI test was not planted.
