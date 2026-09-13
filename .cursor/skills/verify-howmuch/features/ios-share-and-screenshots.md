# iOS share and screenshots

Share and a later screenshot offer are more writers of the same inbox. The extension copies bytes and quits. The main app reads, then the density rule. Default-off screenshot offer lives on Accounts. Issues [#104](https://github.com/yjsoon/howmuch/issues/104), [#106](https://github.com/yjsoon/howmuch/issues/106). Spec: `docs/frontend/intake-ui.md` §9–10.

## Sub-features

- `share-appears` HowMuch appears in the iOS share sheet for `public.image` and `public.text`.
- `share-copies` choosing HowMuch copies the payload and completes; no review UI in the extension.
- `share-reading` main app shows **Reading…** with `Stays on this device`, then `N == 1` capture or **{N} Transactions**.
- `share-no-upload` sharing does not POST the file or a transcript to the HowMuch API.
- `share-one-row` a one-line share can open Add Transaction.
- `share-many` a multi-row share opens the review list.
- `shot-offer` Accounts bottom toast `Add these transactions?` / `Looks like a screenshot · {n} lines`. Tap the toast to add. Swipe away or tap dismiss. Default off.
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

- **Image share.** In Simulator Photos (or any image), Share → HowMuch. Extension completes. HowMuch foreground: title `Reading…`, caption `Stays on this device`, no transcript. Then either Add Transaction or `{N} Transactions`.
- **Text share.** Share a two-line spend list as text. Same Reading… then the review list.
- **No upload.** While Reading… and after confirm **before** Save/Add: `control-howmuch http GET /parse` is 404. No new `/v1` multipart. Network tab / proxy to `{api_url}` shows no image body.
- **Confirm.** Save or `Add {n} to {account}` as in the other recipes. HTTP then shows the rows. Cancel posts nothing.
- **Screenshot offer.** If the Accounts toast is visible, it sits near the bottom of the screen, not in the account list. Headline `Add these transactions?` Caption `Looks like a screenshot · {n} lines`. Tap the toast to follow density. Swipe away or the dismiss control hides it and that photo does not return. Photos still has the shot. If detection is off (the default), the toast is absent — that is a pass for default-off, not a skip, once #106 has shipped the toggle.
- **Proof.** Screenshot the share sheet with HowMuch (`artifacts/ios-share-and-screenshots/share-sheet.png`), Reading… (`artifacts/ios-share-and-screenshots/reading.png`), the resulting capture or list (`artifacts/ios-share-and-screenshots/result.png`). If the offer exists: Accounts card (`artifacts/ios-share-and-screenshots/offer.png`).

## Gotchas

- The extension must not run Foundation Models. If Reading… happens *inside* the share sheet, that is a fail.
- Backgrounded HowMuch must not lose the file; inbox is the source of truth.
- One receipt photo can still be `N == 1` and open Add Transaction. Do not require the list.
- Photos library permission is only for the detection slice. Share from Photos does not require the detection banner.
- Do not verify share by POSTing an image with `control-howmuch http`.
