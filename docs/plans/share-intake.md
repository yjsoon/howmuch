# Share to Halation: document intake

Status: design agreed with the owner, not built. Screens are in [`share-intake/`](share-intake/). Interactive original (owner only): https://claude.ai/artifact/KneQW91pq5pGNh4eqaAprJ

This plan changes two statements in [`docs/frontend/intake-ui.md`](../frontend/intake-ui.md): "No push notifications" (intake uses local notifications) and the blanket "Stays on this device" promise (statement PDFs and some images go to the owner's server and may reach a vision model). Update that doc when the feature lands.

## 1. Why

The owner's real habit is to send screenshots and PDFs to external agents and ask them to change Halation. That is a share-and-review loop, not a conversation. Halation's chat is synchronous (a frozen turn, a typed reply, group-local Save) and its interpreter refuses the owner's second most common job: `CaptureInterpreterPrompt.instructions` in `apps/ios/HowMuch/Capture/CaptureInterpreter.swift` classifies editing saved rows as `unsupported`.

Decision: Share becomes the main way in. Chat becomes follow-up on a batch ("Ask about this batch"). The Assistant keeps its read-only questions (`LedgerQuery.swift`). The floating Assistant button stays; Share and the clipboard offer (`ScreenshotOffer.swift`) become the advertised entry points.

## 2. Jobs to support

1. **Add** new transactions (receipts, payment confirmations, banking app screenshots).
2. **Fix** existing transactions (wrong amount, payee, category, split). The system decides add vs fix itself.
3. **Reconcile** a statement PDF against the register. A separate job type.

## 3. What already exists

- `apps/ios/HowMuchShare/ShareViewController.swift`: accepts one image or text, writes it to the app-group `InboxStore`, immediately opens `howmuch://inbox`. No UI. `Info.plist` allows one image only.
- `apps/ios/HowMuch/Capture/InboxStore.swift`: app-group inbox with `InboxSource` (shareSheet, appIntent, detectedScreenshot) and `InboxPayloadKind` (text, image). No account, note or job state.
- `InboxReadingView.swift`: on-device OCR (`SlipImageText.recognize`) then hands drafts to the conversation.
- Capture AI: on-device Apple Intelligence by default, or BYOK providers (`docs/ai-providers.md`), text only today.
- Drafts commit through `AppModel.commit` and the offline outbox (`docs/plans/offline-writes.md`).
- Reconciliation API: `GET/POST .../accounts/{account}/reconciliation` (`docs/api-contract.md`, around lines 134 to 181), with exact-match assertion.
- Unapproved transactions and the "New to approve" badge (`apps/web/src/lib/unapproved-badge.ts`, iOS `RegisterView` unapproved queue).
- Jev category suggestions (`apps/api/src/categoriser.ts`). See section 11.
- Whole-plan export: `GET /v1/plans/{plan}/export_snapshot` (migration only, no user-facing button).

## 4. Owner decisions

| Question | Decision |
| --- | --- |
| Where reading happens | Hybrid, "fit for purpose": single screenshots on device; PDFs, multi-page and long documents on the server Worker. Thresholds set by evals (section 10). |
| Images to outside models | Allowed. The Worker may send images to a vision model. |
| Flow after Send | Fire and forget; a local notification when ready to review. |
| Auto-saving | High-confidence items may save themselves as **unapproved** ("new"), using a different-colour new indicator (teal) so agent-added rows are obvious. Everything else waits for review. |
| Fix to a reconciled row | Warn, don't block ("Reconciled 6 Oct · approving reopens it"). |
| Skill file and rules storage | On the server when connected, on the device otherwise. |
| External agents | Should read and write the skill file and rules through the API, and submit jobs into the same Inbox. |
| Rules export | Plain text, bundled with other exports (low priority). Needs the "Export everything" feature, which is being built separately. |

## 5. Object model

**Job** (one share action or API submission): `id`, `createdAt`, `origin` (shareSheet, clipboard, appIntent, api with client name such as "OpenClaw"), `sources[]` (images, PDFs, text; several allowed), `accountID` or `decide`, `note`, `hint` (auto, new, fix, statement), `routing` (onDevice, server), `state` (queued, reading, proposed, needsYou, applied, autoSaved, discarded, failed), `evidence` (per-source OCR text, page, bounding regions), `contentHash`.

**Proposal** (one per intended ledger effect): `kind` (add, edit, match, flag), `confidence` 0 to 1, `evidenceRefs[]` (source, page, rect or line indexes), `draft` (a `TransactionDraft` for add; target `transactionID` plus field diff for edit), `reasons[]` (short strings citing rules, the note, the matcher), `decision` (pending, accepted, editedThenAccepted, rejected, autoSaved).

**Reconcile job** adds `statementPeriod`, `openingBalance`, `closingBalance`, and `matched[]`, `missing[]`, `extra[]`.

## 6. Add vs fix

Decide deterministically after extraction, not inside the model prompt.

1. For each extracted line, look for rows in the chosen account within ±3 days (skill file setting) with the same absolute amount; if none, widen to all open accounts.
2. Score by amount exactness, date distance, payee similarity (reuse `payee-names.ts` cleaning) and whether the row is approved.
3. Strong match with differences → **Fix**. Strong match with none → **Already in** (links to the row). Weak match → **New** with "possible duplicate of …". No match → **New**.
4. The note can point at a target ("the Grab one I already added"); the interpreter turns it into a hint, and the matcher confirms it.
5. Ambiguous cases show both options and default to New. Never auto-edit on a weak match. The model never emits a transaction ID it was not shown.
6. The reviewer can flip New to Fix by choosing from the candidates the matcher already computed.

## 7. Screens

All copy is British English and follows the existing house style: warm canvas, white rounded panels, indigo for actions, red outflows and green inflows, monospaced digits, the IntelligenceAura as the only "working" signal (still under Reduce Motion), and existing phrases such as "Saved on device", "Sync pending", "Couldn't load…", "Try Again".

### 7.1 Share sheet ([01](share-intake/01-share-sheet.png))

SwiftUI inside the extension, medium detent. Top to bottom:

- **Cancel** · title **Add to Halation**.
- Items strip: 72pt thumbnails; a PDF is one item with a "PDF · 4 pages" badge; more than four collapse to "+3". Caption "2 screenshots" or "Statement PDF · 4 pages · 1.2 MB". Over the size limit the caption turns red: "Too large to send (limit 8 MB)". Tap to Quick Look.
- **Account** row: defaults to the last-used open account (per `intake-ui.md`). Menu lists open accounts plus **Let Halation decide**, which shows "Picks from the document. You confirm at review." Never closed or deleted accounts.
- **What is this?** segmented: Auto · New · Fix · Statement, with a hint line:
  - Auto: "Halation works out whether each item is new or a correction."
  - New: "Add as new transactions."
  - Fix: "Match to transactions already in the register."
  - Statement: "Reconcile against the register for the statement period." (pre-selected for PDFs)
- **Note** field: "Add a note (optional)", one to three lines.
- **Send**, then a footnote naming where it will be read: "Reads on this phone" or "Sent to your Halation server" (never "sent to AI"), and "Nothing is saved without your review" (or, when auto-save applies, "Sure items save as new for you to approve").

States: items loading (static placeholder under Reduce Motion, Send disabled); not signed in ("Open Halation to finish setting up" with **Open Halation**, and **Save for later** keeps the item in the app group: "Kept on this device until you sign in"); unsupported type ("Halation can read screenshots, photos and PDFs."); offline ("Offline · will process when connected" when server reading is needed); write failure ("Couldn't hand this to Halation. Try again.").

After Send: a 1.2 s "Sent to Halation" pill, `.success` haptic, dismiss. No success screen.

Accessibility: thumbnails "Screenshot 1 of 2", "PDF, 4 pages"; Send reads "Send 2 items to DBS Altitude"; 44pt targets; strip wraps at large Dynamic Type.

Duplicate share: hash the payload (the clipboard offer already SHA-256s images). Same hash within 30 days shows "You shared this on 3 Oct" with **Open** or **Share anyway**.

### 7.2 Notifications and Accounts band ([02](share-intake/02-notification-accounts.png))

Local notifications only (no remote push, no server device registry), category `halation.inbox`, one thread per batch.

- Ready: "Ready to review" · "1 correction found · 1 new, from 2 DBS screenshots". Actions **Review**, **Later**.
- Needs you: "Halation needs you" · "Couldn't tell which account this receipt belongs to."
- Statement: "Statement read" · "Sep 2026 · 41 matched · 2 missing · 1 extra".
- Auto-saved: "Saved 2 as new" · "Approve them in the register when you're ready."
- Failed: "Couldn't read this" · "The PDF was password protected." Actions **Open Inbox**, **Discard**.
- Batches within ten minutes group under "4 batches ready to review". Nothing is applied from a notification; Review always opens the app. Badge = Ready + Needs you.

Server-processed jobs finish while the app is closed, so iOS needs a way to learn about them: background app refresh polling a jobs endpoint is enough for the first version. Remote push is a later option.

Accounts gains an **Inbox** band at the top (only when non-empty), with a count chip, **See all**, and at most two of the most urgent batches. The Accounts tab icon carries the badge. The existing one-off "Add these transactions?" offer card becomes an Inbox batch. No fourth tab.

### 7.3 Inbox ([03](share-intake/03-inbox.png))

Pushed list titled **Inbox**. Sections in order: Needs you, Ready to review, Reading, Auto-saved, Applied, Failed; empty ones are hidden.

Row: thumbnail, source-derived title ("DBS screenshots", "UOB One statement · Sep", "Shopee order · from OpenClaw"), a status pill plus summary ("1 new · 1 fix · 1 already in", "Reading on this phone…"), time. Pills: Reading (grey, aura), Ready / Reconcile (indigo), Needs you (amber), Auto-saved (teal NEW), Applied (green tick), Failed (red).

Swipe: Discard (confirm "Discard this batch? Nothing was saved."), Retry on Failed. Toolbar menu: Clear applied. Empty state: "Nothing waiting" / "Share a screenshot or statement to Halation and it will appear here." Offline footer: "Offline · 2 batches will process when connected".

Accessibility: "DBS screenshots, ready to review, 1 new and 1 fix, 9:41".

### 7.4 Batch review ([04](share-intake/04-batch-review.png))

- Nav: **Close** · "Review" / "2 DBS screenshots · 09:41" · menu (Ask about this batch, Change account for all, Discard batch).
- Document viewer, about 38% of height, collapsible, pinch to zoom, page dots. Proposed rows are outlined and numbered on the source; tapping a region scrolls to its row and vice versa.
- The note, shown as a user bubble, with "Applied to item 1" (green) or "Couldn't apply this note" (amber).
- Groups: **FIX** (before → after, changed fields only, e.g. ~~−12.80~~ −12.60), **NEW**, **POSSIBLE DUPLICATES** (unchecked by default, "Looks like 12 Aug · Grab · −$8.90 already in Everyday Account" with **View existing**), **ALREADY IN** (no action, link to the row).
- Each row: checkbox (checked when confident), payee, category, date, account, amount; confidence word and dot (**Sure** green, **Likely** indigo, **Unsure** amber; never colour alone); ⓘ opens **Why** ("Learned rule: KOPITIAM* → Eating Out (from 4 corrections)", "No row within 3 days for −8.90 in DBS Altitude", "From your note").
- Reconciled target: "⚠ Reconciled 6 Oct · approving reopens it" (amber). Approval is allowed.
- Unsure rows missing an account or category show the existing inline chip picker and block only that row. Partial reads (no amount) are shown but cannot be approved; Approve all skips them and says so.
- Foreign currency: record the SGD charged if printed, else show an unresolved currency chip that blocks the row until the SGD amount is entered; the foreign amount goes in the memo.
- Tap a row to edit in `TransactionFormView`; Done updates the proposal only.
- Bottom bar: **Approve N selected** / **Approve all N**, **Ask about this batch**, **Reject batch**. Approve goes through `AppModel.commit`; toast "1 added, 1 fixed · Saved on device". No auto-dismiss.
- Ask about this batch pushes the shared conversation surface with the batch as context, placeholder "Tell Halation what to change". Replies update proposals in place ("View updated proposal"), never the ledger.

States: Reading ("Rows appear here when the reader finishes."), Needs you (amber banner "Choose an account to continue"), Failed ("Couldn't read this document", **Try Again**, **Discard**), waiting on server while offline ("Waiting for your server"). Wrong account: per-row account picker plus "Apply to all in this batch"; `SlipAccountPick.apply` already clears self-transfers.

### 7.5 Reconcile ([05](share-intake/05-reconcile.png))

- Title "Reconcile" / "UOB One · 1 to 30 Sep 2026".
- Balance panel: "Statement closing" and "Register at 30 Sep" side by side, then "Off by −$14.20" (red) or "Balanced" (green tick), with "Adding the 2 missing balances it".
- Segmented: Matched 41 · Missing 2 · Extra 1. Matched collapsed by default. Missing are New proposals with checkboxes. Extra rows offer **Keep** (not yet posted), **Mark cleared and match…**, **Delete…** (confirmed).
- Footnotes: "Already reconciled through 31 Aug." and "The PDF is deleted from your server once you finish here."
- Bottom: **Add 2 missing**, then **Reconcile through 30 Sep…**, which opens the existing reconciliation sheet with balance and date prefilled so its acknowledgement copy stays the single source. The outbox must drain first (per `offline-writes.md`).
- States: statement for a different account ("This looks like a UOB statement but was sent to DBS", **Switch to UOB**); multi-account statement (one segment per account); unsure period (editable period row).

### 7.6 Remember this? ([06](share-intake/06-remember-this.png))

Half-height sheet after Approve, only when the owner corrected a proposal or resolved an Unsure row and the correction generalises. Never after a reject; at most one per batch.

- Title **Remember this?**; the rule in plain words ("When a Grab line on DBS Altitude has a matching GrabFood receipt, use the receipt total."); scope and evidence ("Scope · DBS Altitude only", "Based on your note and 1 correction today").
- Optional "Also noticed" line confirming an existing rule's track record.
- **Remember**, **Edit…**, **Just this once**. "Just this once" suppresses that suggestion for 30 days.
- Footnote: "Saved to your Halation server · used for future documents only" (or "Saved on device · syncs when connected").

### 7.7 Skill & Memory ([07](share-intake/07-skill-and-memory.png))

Settings → Intelligence → **Skill & Memory**.

- Sync line: "Stored on your Halation server · synced 09:41" or "Stored on this iPhone".
- **Skill file**: one row, "How to read my documents", summary "SGD, Singapore · 6 sources · 1.9k characters".
- **Per account**: one row per open account with its first instruction or "No instructions".
- **Learned**: rules with match → action, provenance ("From 4 corrections · used 11 times", "You said 'always' · 2 Oct"), a toggle, and a warning on rules overridden twice ("Overridden twice · consider removing"). Detail view: structured fields (match type, value, action, scope), source examples linking to the register, **Delete rule** (confirm "Delete this rule? Future documents won't use it.").
- Footer: "Rules and instructions are text only. Rules shape future proposals; they never change saved transactions." **Clear all memory** (destructive).

### 7.8 Skill file editor ([08](share-intake/08-skill-file-editor.png))

Structured settings at the top (currency, date order, duplicate window), then a monospaced markdown editor, character count ("1,912 / 4,000 characters"), **Insert example**, **Done** / **Cancel**. Footer: "Plain instructions. Halation reads this before every document, alongside per-account notes and learned rules. Your other agents can read it too, through the API."

## 8. Skill file format

Structured fields for anything code acts on without a model; a bounded markdown block for interpretation guidance. Per-account entries override global ones. Hard size cap; show the cost.

```yaml
version: 1
locale: { currency: SGD, timezone: Asia/Singapore, dateOrder: dmy }
dedupe: { dayWindow: 3, amountToleranceMilli: 0 }
autoSave: { enabled: true, minConfidence: 0.9, kinds: [add] }
notes: |
  ## Screenshots
  - GrabPay top-ups are transfers from the paying card, not spending.
  - PayNow to a person: payee is the name without "(Mobile ending …)". Ask me if it might be reimbursable.
  - A receipt for a line already in the register is a fix, not a new entry.
  ## Statements
  - Transaction date is the first date column, not the posting date.
  - CR lines are inflows.
  - Foreign spends: record the SGD charged; put "USD 12.00" in the memo.
  ## Categories
  - Food delivery is Eating Out, never Groceries.
accounts:
  - id: acct-dbs-altitude
    notes: "PAYMENT - THANK YOU is a transfer from Everyday."
    dedupeDayWindow: 5
  - id: acct-uob-one
    notes: "CR lines are cashback, not refunds."
```

API: `GET/PUT /api/intake/skill`, `GET/POST/PATCH/DELETE /api/intake/rules`. On device when not connected; sync up on connect (owner decides conflicts if both changed).

## 9. Learning

- Capture from every review: field edits, rejects, New↔Fix flips, notes, auto-saved rows the owner later edited or deleted (a strong negative signal for auto-save).
- A rule: `scope` (global, account, payee), `when` (cleaned payee token, source app, amount sign), `then` (set category, rename payee, treat as transfer to account, flag, prefer receipt total), `origin` (job and decision), `hits`, `overrides`, `lastUsed`, `enabled`.
- Rules are created only through **Remember this?** or an explicit "always" in a note or chat. No silent rules.
- A rule overridden twice is flagged for removal. Deleting a rule never touches saved transactions.
- Every proposal that used a rule cites it in **Why**.
- Export: one rule per line in plain text, bundled with Export everything.

## 10. Routing and evals

Starting rule: one image under N recognised lines → on device; PDF, multi-page or over N lines → server. The share sheet shows the destination; the owner can override it. Do not surface eval scores in the product.

Measure per source type: field accuracy (amount, date, payee, direction), add-vs-fix precision, duplicate recall, latency, cost, and auto-save precision (how often an auto-saved row is later edited or deleted).

Eval set from the owner's own material, de-identified, alongside `fixtures/`, each with an expected-proposals JSON: about 15 GrabPay/PayNow screenshots, 10 card receipts, 5 multi-currency receipts, 3 bank statement PDFs (one scanned), 5 fix cases with the target row and a note, 5 near-duplicates.

Privacy: uploads go only to the owner's Worker over the authenticated session, stored (R2 or D1) for the job's life, deleted on apply or discard. The Worker may send images to a vision model (owner approved). Copy says "Sent to your Halation server", never "sent to AI".

## 11. Where Jev fits (to investigate)

Jev (TypeSafe AI) is already in Halation as a "System One" decision model: it answers a **Choice** question over options the code supplies, returns a probability distribution, and cannot produce a label it wasn't offered (`apps/api/src/categoriser.ts`). Today it picks categories on create, with auto-apply thresholds 0.6 with evidence and 0.85 without.

That shape (code supplies candidates, a fast model picks one, with calibrated-looking confidence) fits several decisions in this pipeline. The implementer should evaluate each against the eval set rather than assume:

1. **Category** for each New proposal. Already built; learned rules sit above it (a matching rule sets the category and skips Jev).
2. **Add vs fix target**: offer the matcher's candidate rows plus "None of these (new)". Jev picks; the deterministic score stays a gate. Could resolve the ambiguous middle band the matcher alone leaves to the owner.
3. **Duplicate or not** for near-matches.
4. **Account** when the owner chose "Let Halation decide": options are open accounts.
5. **Auto-save gate**: Jev's confidence as one input to whether a row saves itself as new, alongside rule hits and matcher strength.
6. **Rule scope** in Remember this?: options global / this account / this payee.
7. **Routing** (on device vs server) from document features, if a heuristic proves too blunt.
8. **Statement line kind** (spend, refund, payment, fee, cashback) for reconcile.

The likely split: a reading model (on-device or vision) extracts text and structure (System Two-ish, slower); deterministic code builds candidates; Jev makes the fast discrete choices; the owner reviews. Questions to answer: latency and cost per batch, how Jev's confidence correlates with correctness on the eval set, whether its distributions are a better auto-save signal than the reader's own confidence, and whether the TypeSafe key (server-only today) means these calls must run on the Worker, which matters for the on-device path when offline.

## 12. Edge cases

- Same document shared twice: content hash (section 7.1).
- Already imported: Already in, with link. Server dedupe by `import_id` and account remains the backstop.
- Multi-currency: section 7.4.
- Partial reads: shown, not approvable.
- Wrong account: per-row picker with apply-to-all.
- Offline: jobs queue; on-device routing proceeds; server routing waits ("Waiting for connection"); approvals go through the outbox; reconcile waits for the outbox to drain.
- 80-line PDF: a reconcile job, reviewed one group at a time with Approve all within a group.
- Fix to reconciled row: warn and allow (owner decision).
- Auto-saved row later wrong: the owner edits or deletes it in the register as usual; record as a negative signal.

## 13. Phases

**First version:** share sheet UI with account, hint, note and destination line; multi-image and PDF activation in `HowMuchShare/Info.plist`; Job and Proposal persisted in the app group; on-device reading only; deterministic matcher; batch review with approve, edit, reject; local notifications; Inbox band; skill file on device; rules only through explicit confirm.

**Deferred from the first version** (the skill file and rules shipped on device only):

- Rule detail does not yet link its source examples to the register; it names the original batch while it is still in the Inbox.
- Currency and date order are stored in the skill file but nothing reads them, so the editor hides them. The duplicate window is live.
- Rule hit and override counts come from approvals in review only, not from later edits made in the register.
- Rules never change a row that is already in the register (Fix and Already in rows); they shape New rows only.
- Skill notes reach only the Apple Intelligence reader, capped at 1,500 characters including account notes.

**Phase 2:** server-side reading on the Worker with file lifecycle and vision models; skill and rules synced to the server with API; reconcile jobs; auto-save as unapproved with the teal indicator; eval harness; Jev decisions that pass the evals.

**Phase 3:** chat follow-up on batches; job submission through the API for external agents (OpenClaw and others), shown with their origin in the Inbox; iPad and web review; rules export through Export everything.

## 14. Riskiest assumptions to test

1. Fire and forget feels trustworthy. Watch for repeat shares of the same document.
2. Auto add-vs-fix is right often enough that Fix rows reassure rather than confuse. Measure flips and rejects.
3. Remember this? feels like control, not nagging. Watch how often it is dismissed and how broad proposed rules are.
4. Auto-save precision is high enough that teal NEW rows rarely need edits.
