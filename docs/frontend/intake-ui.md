# Intake and Assistant

Current iOS capture and Assistant contract. Conversation-first: one chronological surface for Quick Add and Assistant, not a form with a detached draft shelf.

Most use is adding transactions. Occasional use is read-only questions about recorded spending.

## Destinations

Keep **Accounts**, **Plan**, **Reflect**, and **Assistant**. **+** is the native iOS 26 **Add Transactions** tab-view accessory on root destinations only, not a fifth tab. Accessibility label: **Add Transactions**. A visible account-scoped register supplies that account; a hidden retained Accounts stack does not leak. Home Screen Add Expense uses last-used open.

Pushed Assistant conversations hide the tab bar and accessory. Native Back (AX or a real tap on the system control) pops to Assistant home, restores the tab bar and Add accessory, keeps the conversation session, and does not write the ledger. Hosted snapshot tests prove that same `navigationDestination` binding with `UINavigationController.popViewController(animated: false)`, not a synthesized Back tap. Quick Add’s modal covers them.

## Account origin

Resolve account context at session admission. Composer **Account** is the next message only; it does not silently retarget existing drafts.

| Entry | Account |
| --- | --- |
| + from a specific account register | that open account |
| + from overview, Plan, Reflect, or Assistant | last-used **open** account |
| Home Screen **Add Expense** | last-used **open** account, even if a register was left open |
| Duplicate / structured App Intent | the draft’s explicit account |
| Share / inbox | last-used open account |

Prefer last-used to most-used. Fallback: first open account, or **Choose Account** if none. Never a closed or deleted account. Browsing or cancelling does not change last-used. A successful local save or outbox enqueue does.

At Send, freeze the selected account and local date into that user turn. A frozen turn with no account stays without one on retry and does not inherit the later next-message account. Explicit mentions override only when resolved. Ambiguous or unknown account/category choices sit next to the owned preview and block that group’s save. A correction that needs a target lists payee, amount, and date on the clarification reply and does not duplicate those drafts as editable previews. Closed or deleted accounts block that group’s save with Choose an open account. Manual edits update that draft and next-message context only.

## Conversation

User bubbles sit on the right. Assistant prose sits in a shaded incoming bubble on the left. Previews, query results, and clarifications belong to the owning reply. Drafts remain the financial source of truth; each mutable draft has one live preview. Later additions are new groups. Corrections keep the original preview and add a later “View updated draft” link.

Quick Add toolbar: **Close | Add Transactions**. An understated **Open in Assistant** text link sits on the composer account row and opens this same session in Assistant. It is not a toolbar expand icon and not a second bottom Continue CTA. No auto-dismiss after Save. No segmented Describe/Manual control, global Save, bottom Continue, or clipped transcript.

One keyboard-safe dock: compact account line (with Open in Assistant on Quick Add) plus a single white plus/text/send (or Stop) shell. Input grows about 1–5 lines and caps near 120pt. Plus stays reachable during an in-flight model turn so Enter manually can stop that owned work. Photo Library, Camera, and `PasteButton` stay blocked while a turn is busy or an image is ingesting. Native edit-menu paste remains. Pending images live in the shell; sent images live in the user bubble. Blank Quick Add and Assistant **New conversation** focus the field; resume and image entry do not.

## Save

Group-local Save commits only that reply’s included, unsaved draft IDs through `AppModel.commit(_ drafts:)`. Successful local enqueue reads **Saved on device** (and **Sync pending** only when an outbox row exists). No remote-success claim, no cross-group Save, no auto-dismiss. Committed cards are immutable. No Undo back to a recommit. Undo is only on the reply that owns the drafts that actually changed or were removed.

## Manual

Plus → Enter manually opens the existing calculator editor. **Done** resolves arithmetic and applies the local draft preview only. **Cancel** leaves the original values. A new manual draft is created on Done, not before. Done never commits. Quick Add remembers last-used Manual vs chat; Assistant New conversation always opens chat. Stop and Enter manually cancel the owned conversation task as well as late application. Open in Assistant does not. Opening Manual does not cancel in-flight image ingestion.

## Assistant

Home stays at the root: **Today**, **New conversation**, recents. Opening a conversation or Open in Assistant from Quick Add pushes the shared surface. Recents use a short user-derived title, or **Message draft** when only pending text/images exist. History is scoped to endpoint, user, and plan. Discard is a confirmed local action and does not delete saved payments.

Today is the local calendar day, using recorded-spending reports and excluding uncategorised on-budget transfer legs. Loading, unavailable, and zero are distinct. Query answers render once in the owning reply; scope and source sit beneath and do not repeat the detail. Legacy snapshots without `queryID` hydrate each unmatched card onto a matching assistant detail or a system result event so Inspect remains reachable. Source lists use existing matching-payment navigation. Questions cannot mutate saved transactions. No push notifications.

## Apple Intelligence

Show unavailable, downloading, and error states explicitly. Stop and Retry reuse the same frozen turn and reply slot. Later typed text is not swallowed. True unavailable status offers Enter manually, not a fake fallback. There is no cloud or regex fallback. Simulator model unavailability is a validation limit. Tests may inject deterministic doubles.
