# Open-source prep: tokenless setup hardening E2E

Revision: `2751638` (HEAD of chore/open-source-prep) plus uncommitted working tree.
Date: 2026-10-06. Linux sandbox, system Bun 1.4.2 for the servers.

## Setup

- Fresh SQLite files in the session scratchpad (`a.sqlite` .. `d.sqlite`), synthetic data only.
- Ports 18791 to 18794. Token value `e2e-synthetic-token` is a throwaway; password is a synthetic 22-character string.
- Servers started with `bun apps/api/src/server.ts` from the repo root.

## 1. Non-loopback host without a token is refused

Command: `HOWMUCH_HOST=0.0.0.0 PORT=18791 bun apps/api/src/server.ts`

Expected: refusal, exit 1. Observed:

```
Refusing to listen on 0.0.0.0: HOWMUCH_API_TOKEN is not set. Set HOWMUCH_API_TOKEN to serve beyond this machine, or unset HOWMUCH_HOST to listen on 127.0.0.1 only. Also set it if a tunnel or reverse proxy forwards to this server.
exit=1
```

## 2. Non-loopback host with a token starts

Command: `HOWMUCH_HOST=0.0.0.0 HOWMUCH_API_TOKEN=e2e-synthetic-token PORT=18792 bun apps/api/src/server.ts`

Observed: `HowMuch API listening on http://0.0.0.0:18792`; still running when `timeout 3` stopped it (exit 124).

Bracketed IPv6 (`HOWMUCH_HOST=[::1]` with a token) now reaches `Bun.serve` as `::1`, but this sandbox has no IPv6 (`EAFNOSUPPORT: address family not supported`), so the bind could not be observed here. Not verified end to end.

## 3. Default bind and DNS rebinding

Command: `PORT=18794 bun apps/api/src/server.ts` (no HOWMUCH_HOST, no token)

Observed: `HowMuch API listening on http://127.0.0.1:18794`

Rebinding attempt (loopback socket, attacker Host and matching Origin):

```
curl -si -X POST http://127.0.0.1:18794/api/auth/setup \
  -H 'Host: rebind.attacker.example:18794' -H 'Origin: http://rebind.attacker.example:18794' \
  -H 'content-type: application/json' -d '{"username":"attacker","password":"synthetic-password-123"}'
```

```
HTTP/1.1 403 Forbidden
{"error":{"id":"403","name":"forbidden","detail":"Tokenless setup is only allowed from this machine; set HOWMUCH_API_TOKEN"}}
```

`curl -s http://127.0.0.1:18794/api/auth/status` afterwards:

```
{"data":{"setup_required":true,"bootstrap_required":false,"user":null,"session_expires_at":null}}
```

Normal setup (Host and Origin both `127.0.0.1:18794`):

```
curl -si -X POST http://127.0.0.1:18794/api/auth/setup -H 'Origin: http://127.0.0.1:18794' \
  -H 'content-type: application/json' -d '{"username":"owner","password":"synthetic-password-123"}'
```

```
HTTP/1.1 200 OK
set-cookie: __Host-howmuch_session=<redacted>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2591999
{"data":{"user":{"id":"<id>","username":"owner"},"session_expires_at":<epoch>}}
```

Status afterwards: `{"data":{"setup_required":false,...}}`. The persisted result is that only `owner` exists; the `attacker` request created nothing.

## Isolated test

`apps/api/tests/api.test.ts`, "refuses tokenless setup when the Host is not loopback". Written before the fix and failed (`Expected: 403, Received: 200`); passes after the fix. Full suite and engine bundle check results are in the task report.
