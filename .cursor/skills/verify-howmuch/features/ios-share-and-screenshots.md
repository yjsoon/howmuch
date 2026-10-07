# iOS share and screenshots

Share and a later screenshot offer are more writers of the same inbox. The extension copies files and quits. For a share, the main app turns the entry into an Inbox job, reads it on the phone, matches it against the register and waits for **Approve all**. The screenshot offer also becomes an Inbox job; only App Intents still go through the conversation and the density rule. Default-off screenshot offer lives on Accounts. Issues [#104](https://github.com/yjsoon/howmuch/issues/104), [#106](https://github.com/yjsoon/howmuch/issues/106). Spec: `docs/frontend/intake-ui.md` §9–10.

## Sub-features

- `share-appears` HowMuch appears in the iOS share sheet for up to 10 images, one PDF, or text.
- `share-copies` choosing HowMuch shows a sheet with account, kind and note. Send hands the job off without opening the app, and nothing is saved.
- `share-inbox-band` opening Halation shows an **Inbox** band at the top of Accounts, with a count chip (Ready plus Needs you), **See all**, and the batch row: thumbnail, title such as `2 screenshots`, a status pill and a summary.
- `share-reading` while the batch is read the row's pill is **Reading** with `Reading on this phone…`. Reading continues if you leave the Inbox list.
- `share-ready` when reading ends the pill is **Ready** and the summary reads like `1 new · 1 fix · 1 already in`.
- `share-batch` tapping the row opens the batch with FIX, NEW, POSSIBLE DUPLICATES and ALREADY IN groups, each row with its reasons, and **Approve all N** and **Reject batch**.
- `share-approve` **Approve all** adds the ticked new rows and fixes the ticked fix rows, shows `{n} added, {m} fixed · Saved on device`, and the batch moves to **Applied**. A fix keeps the row's approved state.
- `share-reject` **Reject batch** asks `Discard this batch?` / `Nothing was saved.`, then the batch leaves the Inbox and the register is unchanged.
- `share-needs-you` **Let Halation decide** with a line that names no account puts the batch under **Needs you**. Choosing an account moves it to **Ready**.
- `share-failed` an image with no text shows **Failed** with `Couldn’t read this. No text was found.` and a **Retry** swipe.
- `share-no-upload` sharing does not POST the file or a transcript to the HowMuch API.
- `intents-conversation-unchanged` App Intents (Add from Image or Text) still open the conversation, not the Inbox.
- `shot-offer` Accounts bottom toast `Add these transactions?` / `Clipboard image · {n} lines`. Tap the toast to create an Inbox batch (no conversation opens). Swipe away or tap dismiss. Default off.
- `shot-review` Review uses inbox + reader, not a third confirmation UI.
- `shot-dismiss` dismiss does not delete the photo from Photos.

## How to get to it (user POV)

- Photos or Safari share sheet → HowMuch in the app row.
- Shortcuts **Add from Image** / **Add from Text** (#105) when those exist.
- Accounts banner after an opted-in screenshot detection.

Skip this file until a HowMuch share target exists. Report #104. Skip `shot-*` until the Accounts card exists (#106).

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- [iOS connection](./ios-connection.md) signed in.
- Compose/reader already prove typed `N == 1` / `N > 1` ([iOS intake compose](./ios-intake-compose.md), [iOS intake review list](./ios-intake-review-list.md)).
- Share extension `sg.soon.howmuch.share` / App Group `group.sg.soon.howmuch` present.

- **Image share.** In Simulator Photos (or any image), Share → HowMuch, choose the account, kind and optionally a note, then Send. The sheet shows **Sent to Halation** and closes without opening the app. Open HowMuch. The conversation sheet does not open. Accounts shows the **Inbox** band with the batch row and a **Reading** then **Ready** pill, and a summary such as `1 new`.
- **Review and approve.** Tap the row (or **See all**, then the row under **Ready to review**). Check the groups and reasons, then **Approve all N**. Expect the toast `{n} added · Saved on device`, the batch under **Applied**, and the new transactions in the account register (`control-howmuch http GET` the account's transactions and match payee, amount and date).
- **Fix.** Seed a register row, share a screenshot of the same payment with a different payee spelling. Expect a **FIX** row with `Payee … becomes …`. Approve all. The register row keeps its id, takes the new payee, and its approved state is unchanged.
- **Duplicate.** Share the same screenshot again after approving. Expect the line under **ALREADY IN** and no new row.
- **Reject.** Swipe the row, Discard, confirm. The register is unchanged and the shared files are gone from the app group `Jobs/` folder.
- **Text share.** Share a two-line spend list as text. Same band, then a batch with two rows.
- **No upload.** While **Reading** and after Approve: `control-howmuch http GET /parse` is 404. No new `/v1` multipart. Network tab / proxy to `{api_url}` shows no image body.
- **Conversation flows.** Run Add from Image from Shortcuts: it still opens the conversation, not the Inbox.
- **Screenshot offer.** If the Accounts toast is visible, it sits near the bottom of the screen, not in the account list. Headline `Add these transactions?` Caption `Clipboard image · {n} lines`. Tap the toast to create an Inbox batch. Swipe away or the dismiss control hides it and that photo does not return. Photos still has the shot. If detection is off (the default), the toast is absent. That is a pass for default-off, not a skip, once #106 has shipped the toggle.
- **Notification and badge.** Allow notifications when asked (when the first share is adopted with the app open). Share a screenshot, then background Halation before it reads (or lock the phone). Expect a local notification `Ready to review` with `{n} new, from 1 screenshot` style body and actions Review and Later; none while Halation is in front. Review opens Accounts on that batch; Later clears it and applies nothing. The app icon badge and the Accounts tab badge equal Ready plus Needs you and fall as batches are approved or discarded. With two or more batches waiting (Ready or Needs you) and the app in the background: expect one `{n} batches waiting` notification replacing the individual ones, re-posted with the current count as batches are approved or discarded, and replaced by the remaining batch's own notification at one. Later on the summary clears it. A failed read posts `Couldn’t read this` with Open Inbox and Discard; Discard from the notification removes the batch and nothing else changes in the register. Denying permission posts nothing and sets no icon badge; only the Accounts tab badge and the Inbox band remain. `howmuch://inbox/{jobID}` opens that batch and `howmuch://inbox` the Inbox list (with no App Intent entries pending).
- **Duplicate share.** Approve a batch, then share the same screenshot again. Expect `You shared this on {d MMM}` with Close and Share anyway instead of the form; Share anyway shows the normal form and Send makes a second batch. Share two screenshots where one was shared before: `You shared one of these on {d MMM}`. Share the same screenshot twice before opening the app: the second also warns. Every duplicate warning shows `Halation already has this. Open Halation to check.` beneath, not only this case. A discarded or failed batch does not warn. Check `{appGroup}/Intake/hashes.json` holds the content and per-source hashes for jobs from the last 30 days only.
- **Clipboard offer.** With detection on, tap `Add these transactions?`: an Inbox batch appears and the conversation sheet does not open.
- **Proof.** Screenshot the share sheet with HowMuch (`.amp/in/artifacts/ios-share-and-screenshots/share-sheet.png`), the Accounts Inbox band (`.amp/in/artifacts/ios-share-and-screenshots/inbox-band.png`), the batch (`.amp/in/artifacts/ios-share-and-screenshots/batch.png`), and the register row after Approve (`.amp/in/artifacts/ios-share-and-screenshots/result.png`), with the API output for that row. If the offer exists: Accounts card (`.amp/in/artifacts/ios-share-and-screenshots/offer.png`).

## Gotchas

- Store review artifacts under `.amp/in/artifacts/` (AGENTS.md), not the older recipe path.

- OCR or model reading inside the extension is a fail. The extension only copies, hashes and thumbnails.
- Backgrounded HowMuch must not lose the file; inbox is the source of truth.
- One receipt photo can still be `N == 1` and open Add Transaction. Do not require the list.
- Photos library permission is only for the detection slice. Share from Photos does not require the detection banner.
- Do not verify share by POSTing an image with `control-howmuch http`.
- A share must never open the conversation sheet. If it does, the entry was claimed by the old flow: that is a fail.
- Approve writes through the outbox, so offline it shows `Sync pending` and still marks the batch applied. A batch matched while offline lists `Duplicate check limited · offline` and leaves new rows unticked until it is matched again online.
