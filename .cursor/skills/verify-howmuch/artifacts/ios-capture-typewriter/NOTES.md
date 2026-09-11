# iOS capture reply typewriter

Date: 2026-09-09. Darwin `yjmbpro.local`, Xcode 26.6 (17F113).
Branch: `cursor/capture-rename-payee-a557` @ `29f42e7`.
Simulator: HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5).
API: `http://127.0.0.1:60500` (verify stack `20260908T084259-43409`). Never `howmuch.soon.sg`.
Signed in as `verifier` / `howmuch-verify-15`. Plan HowMuch Demo.

## Tests

Stale `test-without-building` ran 0 tests (old xctest). After `build-for-testing`:

`scripts/ios-xcodebuild.sh test -- -only-testing:HowMuchTests/CaptureAssistantPresenceTests`

Executed 6 tests, 0 failures.

## Drive

Floating **Add Transactions** plus → typed `Lunch 12 of Groceries on Everyday Account` → Send.

Mid-type still (`mid-type.png`, burst frame 026, 224 ms before the error): assistant bubble shows **One** (start of **One tick.**) plus **On-device model** / **Still thinking · 0s** and Stop. Not **Let me take a look…**. OCR of frames 024–055 has no that phrase.

Finished still (`finished-reply.png`): Foundation Models `GenerationError error -1`. Failed replies skip the complete-state typewriter (`animate` only when `replyState == .complete`). Retry repeated the same error.

Recording (do not commit): `/tmp/howmuch-typed-replies/session.mp4`.

Successful finished-reply typewriter is proven later on this host with OpenRouter GPT 5.6 Luna. Stills: `artifacts/ios-capture-typed-replies/mid-complete.png` and `finished-complete.png` (PR #155).
