# Export everything: E2E record

- Base revision: `d35b664` plus the uncommitted Export everything change (API route, web Settings section, iOS section, rebuilt engine).
- Date: 2026-10-10. Linux container, Chromium via Playwright 1.56.1. No Xcode, so the iOS section was not compiled or run.
- Fixture: `control-howmuch launch` (seeds `fixtures/demo-ledger.json` into a disposable SQLite stack), synthetic data only.

## Commands

```sh
export PATH="$PWD/.cursor/skills/verify-howmuch/bin:$PATH"
control-howmuch launch && control-howmuch doctor
# web_url / api_url from control-howmuch state
node export.mjs <web_url> .amp/in/artifacts/export-everything      # setup owner, seed, download both files
bun verify.ts <api_url> <archive.json> <transactions.csv> .amp/in/artifacts/export-everything $PWD
node extras.mjs <web_url> .amp/in/artifacts/export-everything      # preferences + Rewards card carried
control-howmuch cleanup
```

(`export.mjs` and `extras.mjs` need the `playwright` package; run them from a directory where it is installed.)

## Steps and expected outcomes

1. First-owner setup in the browser; Ledger appears.
2. As the owner, POST a transaction with payee `=HYPERLINK("http://example.invalid")` and memo `Lunch, "team"` + newline + `second line`, and a -30.00 split into -10.00 and -20.00.
3. Settings shows **Export everything** with two buttons (`settings-export-section.png`).
4. **Download archive (JSON)** saves `halation-export-2026-10-10.json` and shows `Saved …`.
5. **Download transactions (CSV)** saves `halation-transactions-2026-10-10.csv` (`settings-export-saved.png`).
6. The archive's `snapshot` deep-equals `GET export_snapshot`; `settings` and Rewards cards equal their GET endpoints; no password, setup token or token hash appears.
7. The CSV has a BOM, one row per transaction with splits expanded, the formula payee prefixed with `'`, the memo in one cell, and the split as two lines with no parent row.
8. The archive file, unchanged, is POSTed to a fresh empty stack's `import_snapshot`: 201; the restored `export_snapshot` deep-equals the archive snapshot and every account balance matches.
9. After saving account preferences and a Rewards card as the signed-in owner, a new archive carries both.

## Observed

All steps passed. See `browser-steps.log` and `api-checks.log` for the recorded output; the downloaded files are kept beside them.
