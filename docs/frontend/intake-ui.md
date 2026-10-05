# Intake and Assistant

Current iOS capture and Assistant contract. Conversation-first: one chronological surface for Quick Add and Assistant, not a form with a detached draft shelf.

Most use is adding transactions. Occasional use is read-only questions about recorded spending.

## Destinations

The iPhone tab bar is only ever three destinations plus one action: **Accounts**, **Rewards**, and **Reflect**, with a trailing search-role **Add Transaction** button. That Add control is not a fourth tab. Tapping it opens the manual **Add Transaction** form without changing the selected tab. A floating **Assistant** button — a speech bubble with a plus — sits above Add and opens the existing More Assistant overlay (that is how you open chat). There is no in-row chat bubble and no tap-and-hold expanding action on Add. **Plan** still opens from trailing **More**. The iPad regular-width sidebar lists all five destinations and keeps the floating plus. iPad compact width matches iPhone. More also has **Connection settings**. On iPad regular width, More is Connection settings only because Plan and Assistant are already in the sidebar. Accounts on regular width is list | register. The conversation dock still exposes **Add manually**. Accessibility label for the compact Add button: **Add Transaction**. A visible account-scoped register supplies that account for either path. A hidden retained Accounts stack does not leak. Home Screen Add Expense uses last-used open.

Pushed Assistant conversations hide the tab bar, which also hides Add and the floating Assistant. Native Back (AX or a real tap on the system control) pops to Assistant home, restores the tab bar and those controls, keeps the conversation session, and does not write the ledger. Hosted snapshot tests prove that same `navigationDestination` binding with `UINavigationController.popViewController(animated: false)`, not a synthesized Back tap. Quick Add’s modal and any `.blocksCapturePresentation()` sheet hide them too.

The **Add Transaction** App Intent always opens the normal form, blank or prefilled from its structured parameters. **Add from Text** and **Add from Image** continue into conversational capture. No shortcut saves automatically, and remembered entry mode never changes these destinations.

## Account origin

Resolve account context at session admission. Composer **Account** is the next message only; it does not silently retarget existing drafts.

| Entry | Account |
| --- | --- |
| + from a specific account register | that open account |
| + from overview, Rewards, Assistant, Plan, or Reflect | last-used **open** account |
| Home Screen **Add Expense** | last-used **open** account, even if a register was left open |
| Duplicate / structured App Intent | the draft’s explicit account |
| Share / inbox | last-used open account |

Prefer last-used to most-used. Fallback: first open account, or **Choose Account** if none. Never a closed or deleted account. Browsing or cancelling does not change last-used. A successful local save or outbox enqueue does.

At Send, freeze the selected account and local date into that user turn. A frozen turn with no account stays without one on retry and does not inherit the later next-message account. Explicit mentions override only when resolved. Ambiguous or unknown account/category choices sit next to the owned preview and block that group’s save. A correction that needs a target lists payee, amount, and date on the clarification reply and does not duplicate those drafts as editable previews. Closed or deleted accounts block that group’s save with Choose an open account. Manual edits update that draft and next-message context only.

## Conversation

User bubbles sit on the right. Assistant prose sits in a shaded incoming bubble on the left. Previews, query results, and clarifications belong to the owning reply. Drafts remain the financial source of truth; each mutable draft has one live preview. Later additions are new groups. Corrections keep the original preview and add a later “View updated draft” link.

Quick Add toolbar: **Close | Add Transactions**. An understated **Add manually** text action sits on the composer account row and opens the normal transaction form without replacing the conversation. There is no Open in Assistant handoff; saved local conversation history remains accessible from Assistant. No auto-dismiss after a conversation group's Save. No segmented Describe/Manual control, global Save, bottom Continue, or clipped transcript.

While a reply is in flight, the incoming bubble types a short, varying British waiting line character by character, then cycles to another line if the model is still working. Photo turns use slip-reading copy; recorded-spending fetches name the ledger. VoiceOver announces **Working on a reply**, not each letter. Reduce Motion shows the current line in full. A completed reply that just finished generating types out once; history does not replay it. Activity captions stay secondary. Composer ingestion reads **Reading the photo…**. Stop copy is **Stopped — nothing was saved.**

One keyboard-safe dock: compact account line with **Add manually**, plus a single white plus/text/send (or Stop) shell. Input grows about 1–5 lines and caps near 120pt. Add manually stays reachable during an in-flight model turn and stops that owned work. The inner plus opens attachment/paste choices; Photo Library, Camera, and `PasteButton` stay blocked while a turn is busy or an image is ingesting. Native edit-menu paste remains. Pending images live in the shell; sent images live in the user bubble. Blank Quick Add and Assistant **New conversation** focus the field; resume and image entry do not.

## Save

Group-local Save commits only that reply’s included, unsaved draft IDs through `AppModel.commit(_ drafts:)`. Successful local enqueue reads **Saved on device** (and **Sync pending** only when an outbox row exists). No remote-success claim, no cross-group Save, no auto-dismiss. Cards in this conversation stay visible after Save. A later field change (name, category, date, account, amount, direction) updates that row. There is no second Save. Delete remains unsupported. No Undo back to a recommit of the original add. Undo can restore a later field change on that card. Undo is only on the reply that owns the drafts that actually changed or were removed.

## Manual

**Add manually** opens the existing standalone **Add Transaction** sheet with calculator, fields, **Save**, and **Cancel**. Save commits directly once through the normal local outbox path and dismisses the form; there is no extra chat preview requiring another Save. Cancel discards only the form's edits. When opened from a conversation, it inherits the selected account and preserves that conversation's messages, drafts, pending text, and attachments. It does not create or replace a conversation session. Stop and Add manually cancel the owned conversation task as well as late application. Opening Manual does not cancel in-flight image ingestion.

Editing an existing conversation draft remains different: **Done** resolves arithmetic and updates that local draft only; **Cancel** preserves its original values. The owning conversation group still requires explicit Save. New conversational entry always opens chat, regardless of any legacy remembered Manual preference.

## Assistant

Home stays at the root: **Today**, **New conversation**, recents. Opening a recent or new conversation pushes the shared surface. Recents use a short user-derived title, or **Message draft** when only pending text/images exist. History is scoped to endpoint, user, and plan. Discard is a confirmed local action and does not delete saved payments.

Today is the local calendar day, using recorded-spending reports and excluding uncategorised on-budget transfer legs. Loading, unavailable, and zero are distinct. Query answers render once in the owning reply; scope and source sit beneath and do not repeat the detail. Legacy snapshots without `queryID` hydrate each unmatched card onto a matching assistant detail or a system result event so Inspect remains reachable. Source lists use existing matching-payment navigation. Questions cannot delete saved transactions. Field changes to cards still in this conversation revise those rows. No push notifications.

## Apple Intelligence

Show unavailable, downloading, and error states explicitly. Stop and Retry reuse the same frozen turn and reply slot. Later typed text is not swallowed. True unavailable status offers Add manually, not a fake fallback. There is no cloud or regex fallback for reading amounts. A Name / call it / rename line can still update payee when the model returns no spends. Simulator model unavailability is a validation limit. Tests may inject deterministic doubles. In-flight replies use typed waiting copy rather than a single frozen status line.
