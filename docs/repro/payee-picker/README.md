# Payee picker real-tap repro (not for merging)

This branch adds a throwaway `HowMuchUITests` target, a `HowMuchUITests` scheme and `PayeePickerRealTapUITests.swift`. They drive the app with real synthesised HID touches against a local API. They are verification tooling for the payee picker fix PR only; do not merge this branch. The full procedure is in that PR's description.

Screenshots:

- `before-orphaned-search.png`: unfixed build. The popped picker's search is left over the form, and the navigation bar and Cancel button are hidden.
- `after-payee-empty.png`, `after-payee-typed.png`, `after-category.png`: fixed build, inline search field.
