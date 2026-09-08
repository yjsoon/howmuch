# Rewards flag colour names

- Run: `20260908T083732-59560`
- Web: `http://127.0.0.1:59151`
- API: `http://127.0.0.1:49463`
- Owner: `verifier` via Sign in

## Drive

1. Open Travel Card editor (`/rewards/card_dac99df5-e82f-4c44-8c81-0f5195289422`). Colour names fieldset is present. Red `Dining`, Blue `Online`. Other colours blank. `editor.png`.
2. Save card. Board returns to heading `Rewards`. `board.png`.
3. Re-open the editor. Red/Blue inputs still `Dining` / `Online`. Account ledger FlagTag `textContent` is `Dining` / `Online` (CSS shows DINING / ONLINE). FlagPicker captions are Dining and Online. `ledger.png`.
4. Travel Card register (`/transactions?range=all&accounts=acct-credit`). Heading `Travel Card`. Payee FlagTags: Candlenut/Scoot/Grab `Dining`, MUJI `Online`. Not RED/BLUE. `register.png`.
5. Everyday Account register. Heading `Everyday Account`. No named colour FlagTags. `everyday.png`.

## HTTP

`GET /api/import/rewards-tracker?plan_id=local-plan` card `flagNames`: `{ "red": "Dining", "blue": "Online" }`. Subcategory name for red is `Dining`. Travel Card rows: three `flag_color=red` / `flag_name=Dining`, one `blue` / `Online`.

Linux cannot run Simulator. iOS Colour names section plus `RewardCardEditorTests` cover encode and overlay titles.
