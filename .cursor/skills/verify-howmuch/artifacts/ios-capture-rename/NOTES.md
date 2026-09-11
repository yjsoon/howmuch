# iOS capture rename a saved card

Date: 2026-09-11. Darwin `yjmbpro.local`, Xcode 26.6 (17F113).
Branch: `cursor/capture-rename-payee-a557` @ `29f42e7`.
Simulator: HowMuch Verification `BA2CAD1A-0977-4290-8486-760091B333AE` (iOS 26.5).
API: `http://127.0.0.1:60500` (verify stack `20260908T084259-43409`). Never `howmuch.soon.sg`.
Signed in as `verifier` / `howmuch-verify-15`. Plan HowMuch Demo.

## Tests

After `build-for-testing` on that UDID:

`scripts/ios-xcodebuild.sh test --` CaptureAssistantPresenceTests, the payee-rename CaptureSessionTests, and the CaptureInterpreterTests rename cases.

Executed 13 tests, 0 failures.

## Drive

Remote OpenRouter GPT 5.6 Luna (financial-text consent on). Unsigned `CODE_SIGNING_ALLOWED=NO` cannot store the API key; an ad-hoc-signed Simulator Debug build can.

1. Floating **Add Transactions** plus → `Lunch 12 of Groceries on Everyday Account` → Send.
2. **Save transaction** on the Lunch −$12.00 Groceries card. Status **Saved on device**.
3. Type `Name Capture Rename Verify` → Send.

The same card updates to payee **Capture Rename Verify**, amount still −$12.00, caption **Updated after your correction**. Assistant: `The saved lunch card has been renamed to “Capture Rename Verify”.` It does not invent a second payment.

HTTP `GET /v1/plans/local-plan/transactions?since_date=2026-09-11&until_date=2026-09-11`: same id `txn_8a87d2de-7971-4efd-b163-49f30a29d400`, `payee_name` `Capture Rename Verify`, `amount` `-12000`, `account_id` `acct-everyday`.
