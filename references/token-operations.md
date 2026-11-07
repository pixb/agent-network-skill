# Token operations and troubleshooting

Companion to `SKILL.md` §0.1. Read this **before** touching a token: revocation is irreversible, and
the CLI's output is deliberately thinner than you expect.

## What the hub actually does

- **Every login adds a token; the old ones stay valid.** `anet login` (CLI, dashboard, a second
  machine) issues its own utok each time and **does not rotate or kick out the previous ones**. A long
  list of `user-login` rows in `anet token ls` is normal. The practical rule is **one token per
  machine**, revoked when that machine is retired.
- **What idle-expires.** A utok (`scope='user'`, not network-bound) expires after
  `COMMHUB_SESSION_IDLE_DAYS` days of disuse (default 30; 0 = off). **`atok_` and `ntok_` never
  expire** — they are long-lived credentials, and only manual revocation ends them.
- **`last_used_at` has hour granularity** (written at most once an hour). Never read it as
  second-by-second proof that somebody is present.
- **The hub stores only sha256 and records no IP.** The plaintext cannot be reversed, so "which
  machine is using this token" is unanswerable from the hub alone. The only evidence is login
  metadata: a CLI login is `kind=cli` with `client_label` "`anet <version> · <host> · <subcommand>`";
  **a dashboard / browser / app login is `kind=login` with no label**.
- **`Session expired. Run: anet login`** means *this* login token was revoked or idle-expired. Log in
  again; **other machines are unaffected** — logging in does not rotate anyone else's token.

## Identifying a token

`anet token ls` is not enough: it shows ID / NAME / CREATED / LAST USED, **no label and no kind**, and
its times are **UTC** (8 hours behind local — don't read a token you just created as "yesterday's").

- Device and current-session detail: `GET /api/auth/sessions` (includes `is_current`; needs a user
  token).
- To prove *which* token this machine is using when you can read the hub DB: take the plaintext from
  local config (`token` in `~/.anet/config.json`) and compare
  `printf %s '<plaintext>' | sha256sum` against `api_tokens.token_hash` (`hashToken()` is bare sha256
  hex).

## Revoking

- `anet token revoke <token-id>` is a **hard delete with no undo**, and it accepts **user tokens
  only** (node tokens are refused).
- Revoking a node's `ntok_` = that node gets a **401 on its next start** and must be re-created with
  `anet node create`.
- **Back up the hub database (including the `-wal` / `-shm` files) before touching anything.**

## The 401 you are staring at

`401 unauthorized` on `/mcp` is a token problem before it is a hub problem: run `anet whoami`, or the
curl self-check in `SKILL.md` §0.2. With no token, **no** tool on `/mcp` is callable. The hub relents
only when it was started with `--dev-open` and `COMMHUB_TOKEN` is unset — and the CLI's local login
gate still stands in that case, so "I never configured a token" does not mean "there is no token".

Environment contamination is the other half of this: with several machines sharing a session, or
several hubs around, `COMMHUB_URL` / `COMMHUB_TOKEN` bleed across. Sanitize with
`env -u COMMHUB_URL -u COMMHUB_TOKEN` (or pass the values explicitly), then re-run.
