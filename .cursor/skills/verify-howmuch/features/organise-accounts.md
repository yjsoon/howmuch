# Organise accounts

Organise accounts is a dialog on the signed-in shell. Favourites and custom groups write to synced preferences and change the sidebar.

## Sub-features

- `organise-open` opens the dialog from the **Organise** button in the account list.
- `organise-favourite` stars Everyday Account into Favourites.
- `organise-group` creates a custom group and puts Travel Card in it.
- `organise-sidebar` shows those groups after close.

## How to get to it (user POV)

- Choose **Organise** beside the `Accounts` heading in the sidebar account list (outside Primary navigation).
- There is no standalone route. The dialog sits on whatever page is open.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Seeded accounts Everyday Account, Rainy Day Saver, and Travel Card still exist.

- **Open dialog.** Choose `Organise` in the account list. Dialog heading is `Organise accounts`. Sections include `Favourites` and `Custom groups`.
- **Favourite.** Under `Choose favourite accounts`, tick `Everyday Account`.
- **Custom group.** Choose `+ New group`. Group name `Verify Cards`. Choose `Create`. Open `Choose accounts` on that group. Tick `Travel Card`.
- **Close.** Choose `Close account organiser` (the ×). The dialog closes.
- **Sidebar.** Band `Your groups` lists Favourites (Everyday Account) and `Verify Cards` (Travel Card). Band `By type` still lists Cash / Credit.
- **Proof.** Screenshot the open dialog with the new group (`artifacts/organise-accounts/dialog.png`) and the sidebar after close (`artifacts/organise-accounts/sidebar.png`).

## Gotchas

- Preferences save as you tick. There is no separate Save. Closing keeps the last successful sync.
- Built-in names (Favourites, Cash, Credit, Tracking, Closed) are reserved. `Verify Cards` is safe.
- Viewport ≤720px hides the sidebar. Open **Open menu** before **Organise**; the account list sits inside the drawer.
- If the dialog says `Editing is unavailable`, the API build is too old for synced preferences. That is `verified-unreachable`, not a pass.
