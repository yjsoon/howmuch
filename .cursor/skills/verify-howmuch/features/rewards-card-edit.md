# Rewards card edit

Rewards cards are stored on the plan and edited in HowMuch. **Add card** opens `/rewards/new` to put rewards rules on an existing HowMuch credit card. A tile opens `/rewards/:cardId`. The board hides a card whose calculation reports that maximum spend is exceeded. The editor URL still opens that card.

## Sub-features

- `rewards-add-card` shows **Add card** on the empty board and the filled board, and opens `/rewards/new`.
- `rewards-create` saves a native card mapped to **Travel Card** and returns to Rewards.
- `rewards-edit-delete` loads a stored card at `/rewards/:cardId`, then **Delete card** after the in-page confirm.
- `rewards-capped-hidden` hides a capped tile on the board and still opens the same card at `/rewards/:cardId`.

## How to get to it (user POV)

- Choose **Rewards**, then **Add card**.
- Open `{web_url}/rewards/new`.
- Choose a tile on Rewards, or open `{web_url}/rewards/{cardId}`.

## Driving it with control-howmuch

Preconditions:

- `control-howmuch doctor` passes.
- Owner `verifier` is signed in.
- Demo ledger still contains Travel Card.
- Stay on range **All**. Demo spends are 2026-03-01 through 2026-05-24.

- **Open empty.** Open `{web_url}/rewards`. Title is `Rewards · HowMuch`. Heading is `Rewards`. **Add card** is present. Status mentions `Settings → Rewards import` and **Add card**.
- **Open editor.** Choose **Add card**. Title is `Add card · HowMuch`. Route is `/rewards/new`. Heading is `Add card`. Section is `Existing HowMuch card`. HowMuch card picker lists `Travel Card`, not Everyday Account.
- **Create.** HowMuch card `Travel Card`. Name fills to `Travel Card`. Issuer `UOB`. Type `Cashback`. Featured stays checked. Earning rate `1`. Choose **Save card**. Rewards lists a Cashback tile named `Travel Card`.
- **Edit.** Choose the `Travel Card` cashback tile. Title is `Edit card · HowMuch`. HowMuch card is `Travel Card`. The account ledger lists Travel Card rows. Choose **Delete card**. Confirm heading is `Delete this reward card?`. Choose **Delete card**. Rewards no longer lists that cashback `Travel Card`.
- **Lane 5.** Import `fixtures/rewards-tracker-export.json` from Settings → Rewards import if Travel Card is not already stored. Open `{web_url}/rewards/card-travel`. Set Maximum spend to `1`. Choose **Save card**. The Rewards board omits the Travel Card tile. Open `{web_url}/rewards/card-travel` again. The editor still opens with heading `Edit card` and account `Travel Card`.
- **Proof.** Screenshot empty Rewards with **Add card** (`artifacts/rewards-card-edit/empty.png`), `/rewards/new` (`artifacts/rewards-card-edit/new.png`), the board after create (`artifacts/rewards-card-edit/created.png`), the board after the capped save (`artifacts/rewards-card-edit/capped-hidden.png`), and the editor still open for `card-travel` (`artifacts/rewards-card-edit/capped-editor.png`).

## Gotchas

- Empty state is only when the rewards report returns no cards. An all-capped board still has stored cards, so the empty panel stays away.
- **Add card** is the control on the board and in the empty copy. Both go to `/rewards/new`. The editor picks an existing credit card account. It does not invent a new ledger account.
- Flag colour on a subcategory uses the same FlagPicker colour tags as the ledger (None plus the six colours). None stores `unflagged` and matches unflagged spend. Ledger None sends `null`.
- Viewport ≤720px hides the sidebar. Open **Open menu** before **Rewards**.
