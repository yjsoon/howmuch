# iOS capture typed replies

Date: 2026-09-11. Darwin `yjmbpro.local`, arm64, Xcode 26.6 (17F113).
Simulator: HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5).
API: `http://127.0.0.1:60500` (verify stack `20260908T084259-43409`). Never `howmuch.soon.sg`.
Signed in as `verifier`. Plan HowMuch Demo.

## `typed-wait` (already proven 2026-09-09)

On-device Apple Intelligence. Mid-type still `../ios-capture-typewriter/mid-type.png`: **One** (start of **One tick.**) plus **On-device model** / **Still thinking · 0s**. Not **Let me take a look…**.

Failed on-device replies dump in full (`typed-reply-failed-dumps`): `../ios-capture-typewriter/finished-reply.png` is `GenerationError error -1`.

## `typed-reply-complete` (proven 2026-09-11)

Do not retry on-device Foundation Models on this UDID. `scripts/ios-xcodebuild.sh` unsigned products cannot store an API key (`errSecMissingEntitlement`). An ad-hoc-signed Simulator Debug build can.

Remote provider: OpenRouter **GPT 5.6 Luna**. Financial-text consent on. Connection stayed on the verify API.

Drive: floating **Add Transactions** plus → `Lunch 12 of Groceries on Everyday Account` → Send.

- Waiting still (frame 000): **On** plus **OpenRouter · GPT 5.6 Luna** / **Still thinking · 0s**.
- `mid-complete.png` (burst frame 012): success copy mid-type — `I've prepared a £12 lunch draft in Groceries for Ever` plus cursor. Lunch −$12.00 Groceries draft already on screen.
- `finished-complete.png`: full helper text and the Lunch −$12.00 **Not saved** card. Not a Foundation Models error dump. Not waiting-line copy.

Assistant copy used £ while the card shows −$12.00. That is the model’s wording, not a typewriter miss.

Burst frames (do not commit): `/tmp/howmuch-typed-replies-complete/frames/`.
