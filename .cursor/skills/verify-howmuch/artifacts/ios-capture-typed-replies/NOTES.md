# iOS capture typed replies — leftover proof

Do not treat this file as a pass for `typed-reply-complete`. Update it when that sub-feature is actually driven.

## Already proven (`typed-wait`)

Host: Darwin `yjmbpro.local`, arm64, Xcode 26.6 (17F113).
Simulator: HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5).
Branch / commit: `cursor/capture-rename-payee-a557` @ `29f42e7`.
PR: [#153](https://github.com/yjsoon/howmuch/pull/153).

`CaptureAssistantPresenceTests`: 6 tests, 0 failures, after `build-for-testing` (a `test` without rebuild ran 0 tests against a stale bundle).

Drive: floating Add Transactions plus → `Lunch 12 of Groceries on Everyday Account` → Send.

Mid-type still: `/tmp/howmuch-typed-replies/mid-type.png` (burst frame 026). Assistant showed **One** (start of **One tick.**) plus **On-device model** / **Still thinking · 0s** + Stop. Not **Let me take a look…**. OCR of frames 024–055 had none of that phrase.

## Not proven (`typed-reply-complete`)

On-device Foundation Models on that Simulator returned:

`I could not read that. The operation couldn’t be completed. (FoundationModels.LanguageModelSession.GenerationError error -1.) Your drafts are still here.`

Retry hit the same error. Failed replies dump in full, so the 34 cps finished-text typewriter never ran.

Finished error still: `/tmp/howmuch-typed-replies/finished-reply.png`.
Session video (do not commit): `/tmp/howmuch-typed-replies/session.mp4`.

## What the next run must do

1. Run on howmuch-mac. Pin the Verification UDID. `build-for-testing` before test/install. Do not `simctl io booted`. Do not `HOWMUCH_SHUTDOWN_OTHER_SIMULATORS=1`.
2. Do not retry on-device Apple Intelligence on `BA2CAD1A-0977-4290-8486-760091B333AE`.
3. Need an operator-supplied AI provider key. Add Transactions → **AI provider** → remote provider + **Allow sending financial text**. Never `howmuch.soon.sg`.
4. Same Lunch $12 send. Burst-capture mid-type of the **success** reply, then a finished frame with the draft card.
5. Write `mid-complete.png` and `finished-complete.png` next to this file. Do not commit the mp4.
