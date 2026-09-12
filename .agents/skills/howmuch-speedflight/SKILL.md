---
name: howmuch-speedflight
description: Publish a HowMuch iOS build to a registered iPhone via Speedflight (speedflight.dev) from this repo. Use when the user explicitly authorizes a signed ad hoc publication — "cut a build", "send me the build", "put this on my phone", "/speedflight" — or when preflighting whether this Mac can publish. Covers the authorization gate, revision selection, Tinkertanker signing preflight, and private link handoff. Not a validation step: local builds and simulator tests do not need this skill.
---

# HowMuch Speedflight publication

This is the HowMuch-specific policy layer for the generic `speedflight` agent
skill. The mechanics (setup, script anatomy, CI option, API) live in that
skill; the pipeline itself is `scripts/speedflight.sh`; the authoritative
runbook is `docs/speedflight.md`. Read the runbook before any publication.
This skill exists so any agent — not just one IDE — applies the same gates.

## Authorization gate (first, always)

Speedflight is signed archive, ad hoc export, and external distribution in one
command. Run it **only when the user explicitly authorizes that publication**.
Completed iOS work, a passing build, or a local test request does not
authorize it. If the handoff looks obvious (the user's phone is not plugged
in and they want the build), *offer* it and wait for the yes — do not cut the
IPA on inference. Validation never requires this skill: use
`scripts/ios-xcodebuild.sh` and `apps/ios/AGENTS.md` instead.

A failed or completed run does not authorize another one; each publication
needs its own authorization.

## Select and preserve the requested revision

Never cut an IPA from a stale local checkout.

1. `git fetch origin` (verify it is `yjsoon/howmuch`), then resolve the
   requested branch/tag/SHA. An explicit SHA or tag wins over newer code;
   an unqualified "latest" request resolves to fetched `origin/main`.
2. Record the resolved commit and build a clean checkout at exactly that
   revision. Do not merge/rebase the requested branch, substitute newer
   code, or silently include local fixes in an exact-commit build.
3. Set `SPEEDFLIGHT_SOURCE_REF` to the full containing ref
   (`refs/heads/main`, `refs/tags/<tag>`). The script fetches only that ref
   and checks HEAD containment without moving HEAD.
4. If the tree is dirty or HEAD is not pushed, stop and report the
   prerequisite. Do not commit or push to satisfy it without authorization.

## Preflight on the publishing Mac

Confirm without printing secrets. Full checklist and blocker table:
`docs/speedflight.md` ("Preflight" and "Blockers and owner setup").

1. Darwin with working `xcodebuild`. No Linux/cloud VM, and no CI workflow
   exists — creating one requires an explicit request.
2. Gitignored `.env.speedflight` defines `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_PRIVATE_KEY_PATH` (explicit path, mode `600`), `SPEEDFLIGHT_SECRET`,
   `SPEEDFLIGHT_DEEP_LINK=howmuch://`, `SPEEDFLIGHT_AUTHOR`.
3. The `.p8` belongs to **Tinkertanker `PQ6U5ESLN2`**, which owns
   **`sg.soon.howmuch`**. A **T Krobot `XL5JK4F896`** key may authenticate
   but cannot sign this bundle. **Never** change `DEVELOPMENT_TEAM` to make
   a wrong-team key work, never archive unsigned, and never create or
   revoke certificates/profiles by hand.
4. The target iPhone is registered in the Tinkertanker ad hoc profile.
   Simulator success does not satisfy this.
5. If any check fails: stop, report the failed check, and give the
   applicable remedy from the runbook's blocker table. Preflight failures
   do not authorize credential, team, or project mutations.

## Run and hand off

```sh
SPEEDFLIGHT_SOURCE_REF=refs/heads/main scripts/speedflight.sh "<one-line title>" "<what changed and what to test>"
```

Title is one line; notes say what changed and what to test, written for the
person holding the phone. Optional privacy-safe screenshots follow the notes.

Post the `Build page: https://speedflight.dev/a/<pageId>` URL as a plain URL
on its own line **only in the authorized private chat** — never in PRs,
issues, commit messages, or public logs, and never a URL with a build id
after the page id. The link is the install authorization. Never print
`SPEEDFLIGHT_SECRET`. Report upload and physical installation separately:
an uploaded IPA is not proof the phone installed it.
