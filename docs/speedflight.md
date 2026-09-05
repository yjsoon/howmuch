# Speedflight publication

`scripts/speedflight.sh` signs a Release archive, exports an ad hoc IPA, and uploads it to Speedflight in one invocation. Run it only when that publication is explicitly authorized. A local build/test request or completed iOS work does not authorize signing, provisioning, distribution, commits, or pushes.

For local validation, use [apps/ios/AGENTS.md](../apps/ios/AGENTS.md). Safe local fixes and reruns can continue within the task; they need neither signing secrets nor a clean/pushed HEAD. An unsigned simulator or device-architecture build is not physical-device installation evidence.

## Select and preserve the requested revision

1. Verify `origin` is the intended `yjsoon/howmuch` repository and fetch the requested remote branch/tag. An explicit SHA/tag takes precedence over newer code. Otherwise resolve the fetched named branch; for an unqualified request for the latest published build, resolve fetched `origin/main`.
2. Record the resolved commit and use a clean checkout at that revision. Do not switch a dirty checkout, merge/rebase a requested branch onto `main`, or substitute a newer revision. Coordinate checkout changes with its owner.
3. Publication requires HEAD to be contained in a freshly fetched branch or tag on `origin`. Set `SPEEDFLIGHT_SOURCE_REF` to that full ref, such as `refs/heads/main` or `refs/tags/<tag>`. It is required for detached HEAD; on an attached branch it defaults to `refs/heads/<current-branch>`. For an exact SHA, select a remote branch/tag containing it. The script fetches only that ref and checks containment without moving HEAD; it does not enforce the human's requested SHA, so verify HEAD against the recorded revision before running it.
4. If cleanliness or remote provenance is unmet, stop publication and report the prerequisite. Do not commit/push to satisfy it without authorization. Authorized fixes may be developed and tested locally, but an exact-commit build must not silently include them; a changed revision and any commit/push need the corresponding permission.

The page records the exact HEAD commit and the containing branch/tag name. Local tags, stale remote-tracking refs, or `CI=1` are not substitutes for origin verification. If shallow history prevents proving ancestry, fetch the needed history rather than bypass the check.

## Preflight on the publishing Mac

Confirm these checks without printing secrets or private provisioning/device data. The script checks required values, key-file existence, and Git provenance; Darwin, key permissions/ownership, signing readiness, and device registration remain operator preflight duties.

1. `uname` is Darwin and `xcodebuild -version` works. Do not run Speedflight on Linux or a cloud VM without Xcode. There is currently no Speedflight GitHub Actions workflow; creating or triggering a CI publication path requires an explicit request.
2. Gitignored `.env.speedflight` defines `ASC_KEY_ID`, `ASC_ISSUER_ID` (not `ASC_ISSSUER_ID`), `ASC_PRIVATE_KEY_PATH`, `SPEEDFLIGHT_SECRET`, `SPEEDFLIGHT_DEEP_LINK=howmuch://`, and `SPEEDFLIGHT_AUTHOR`.
3. The `.p8` at the configured `ASC_PRIVATE_KEY_PATH` exists and is mode `600`. Set the path explicitly rather than rely on the script's `$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8` fallback. Historical Mac example: `~/Dropbox/private_keys/AuthKey_TinkertankerAdmin_K3832HFK5M.p8` (key ID `K3832HFK5M`); do not assume it exists on another runner.
4. The key belongs to **Tinkertanker `PQ6U5ESLN2`**, which owns **`sg.soon.howmuch`**. Verify the key's team and bundle using ASC authentication and bundle-ID inspection (`asc auth login` / `asc bundle-ids`, `seedId` and identifier). A **T Krobot `XL5JK4F896`** key may authenticate but cannot sign this bundle. Never change `DEVELOPMENT_TEAM` to make a wrong-team key work.
5. The intended physical iPhone is registered in the **Tinkertanker** ad hoc profile. Registration with T Krobot does not count. Simulator success cannot satisfy this gate.
6. The selected clean revision satisfies the provenance contract above, and one owner coordinates all Xcode work on this Mac/checkout.

`DVTDeveloperAccountManager` / missing `Xcode-Token` messages alone are not a blocker when the three `-authenticationKey*` flags are supplied: cloud signing uses the `.p8`, not the Xcode GUI account. Actual signing errors must still be resolved.

## Blockers and owner setup

Report the failed check and the applicable remedy below; this table does not authorize credential/account mutations. Do not archive unsigned, switch signing teams, or create certificates/profiles by hand.

| Gap | Owner remedy |
|---|---|
| Not Darwin / no Xcode | Use a suitable Mac, or explicitly request a CI setup/publication path. `CODE_SIGNING_ALLOWED=NO` is not a substitute for signed distribution. |
| Missing `.env.speedflight` / upload secret | Restore the private configuration and the correct existing upload secret. For an explicitly authorized new setup, mint a secret with `openssl rand -hex 24`; do not replace an existing app's upload identity accidentally. Keep `SPEEDFLIGHT_DEEP_LINK=howmuch://`. |
| Missing ASC key ID / issuer | App Store Connect → Users and Access → Integrations → App Store Connect API, with **Tinkertanker** selected. Issuer ID is per team; a new Team Key should be Admin or App Manager. |
| Missing `.p8` | The key downloads once. Locate the saved Tinkertanker key, set its explicit path, and use mode `600`. A replacement key requires owner action. |
| `.p8` is `644` | Correct the configured key's mode to `600` with authorization. |
| `seedId` is not `PQ6U5ESLN2` | Obtain a Tinkertanker Team Key. Keep any T Krobot key for TK apps. |
| Bundle ID reported unavailable | Check key/team ownership; do not change the app's `PQ6U5ESLN2` team or `sg.soon.howmuch` bundle ID. |
| Device cannot install | Register its UDID with Tinkertanker and include it in that team's ad hoc profile, or connect it once after the correct key works. No unregistered-device workaround. |
| Dirty or local-only revision | Report the unmet prerequisite; request any necessary commit/push or revised-build authorization. Do not discard unrelated changes. |

## Archive and private handoff

Only after authorization and preflight, run from the repository root with the selected source ref:

```sh
SPEEDFLIGHT_SOURCE_REF=refs/heads/main scripts/speedflight.sh "<one-line title>" "<what changed and what to test>"
```

Replace `refs/heads/main` with the selected full branch/tag ref when appropriate. Optional screenshot paths follow the notes; include only authorized, privacy-safe images.

The script owns canonical Release signing/archive/export arguments, including `-allowProvisioningUpdates`, automatic signing for Tinkertanker, `-jobs 2`, and CLI-only index-store suppression. Keep its signed archive: unsigned archives lose entitlements that export re-signing does not restore. Do not hand-create signing assets or change project signing settings.

Keep `build/xcode/DerivedData-archive` separate from simulator/device caches. Archive/export products live in `build/share`, which the script replaces on each run; preserve any needed prior evidence privately before a new authorized run. Keep diagnostic logs outside DerivedData under `build/xcode/logs`. Do not erase shared caches, terminate another owner's work, or launch competing Xcode workloads. Use the available `validating-xcode-runners` skill for diagnosis rather than duplicating its process/memory playbook here. A failure does not authorize another publication; diagnose and test locally within scope before retrying an authorized handoff. Do not install external skills as a workaround.

Post `Build page: https://speedflight.dev/a/<pageId>` as a plain URL on its own line **only in the authorized private chat**. The page URL is installation authorization: open it in Safari on a Tinkertanker-registered iPhone. Never put it in PRs, issues, public logs, or other public text; never share a URL with a build ID after the page ID. Never print `SPEEDFLIGHT_SECRET` or expose it in shell tracing. Report archive/export/upload and physical installation separately; an uploaded IPA is not proof that the phone installed it.
