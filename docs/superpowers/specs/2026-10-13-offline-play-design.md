# Offline Play with Custom Name — Design Spec

Date: 2026-10-13
Status: Approved (conversational design §§1–4 accepted; user authorized auto-continue to implementation)
Approach: A — first-class offline accounts in `minecraft_users`

## 1. Intent

Allow playing the game completely offline with a customizable name, without
requiring Microsoft login. The requester owns Minecraft on their Microsoft
account but will be without internet access soon, so the offline identity must
launch with no network at all.

Agreed scope decisions:

- Launch behavior: "everything as normal" — no artificial single-player-only
  gate. Servers with `online-mode=false` (no auth check) are fully joinable
  with the offline identity; servers with `online-mode=true` will reject
  offline sessions on their own and the launcher does not pre-block either
  case.
- Account model: multiple offline profiles coexisting side-by-side with
  Microsoft accounts, sharing the single `active` selection.
- UUID: deterministic vanilla offline UUID (MD5 of `OfflinePlayer:<name>`
  with v3/variant bits), so recreating the same name keeps worlds/saves,
  matching vanilla offline mode and PrismLauncher/MultiMC.
- Rename = new identity: renaming recomputes the UUID. Old worlds stay under
  the old name/UUID.

## 2. Background (as-found)

- Auth lives in `packages/app-lib/src/state/minecraft_auth.rs` (`Credentials`,
  `login_begin`/`login_finish`, refresh, profile cache) exposed via
  `packages/app-lib/src/api/minecraft_auth.rs` Tauri commands
  (`plugin:auth|login`, `get_default_user`, `set_default_user`,
  `remove_user`, `get_users`).
- Schema: `migrations/20240711194701_init.sql` creates `minecraft_users`
  (`uuid`, `active`, `username`, `access_token`, `refresh_token`, `expires`,
  all effectively required). No account-type concept.
- Launch requires credentials: `api/instance/run.rs:55-57`
  (`get_default_credential` → `NoCredentialsError` → frontend
  `MinecraftRequiredModal`). Launcher args in `launcher/args.rs` hardcode
  `user_type = "msa"` (`args.rs:354`) and use the real access token.
- `Credentials::maybe_online_profile()` already falls back to the stored
  offline profile when the network/profile fetch fails — the steady-state
  behavior offline accounts will rely on permanently.
- `run.rs:247-292` session-server `join` (for server-project links) only warns
  on failure today; with no network it would sit through retries/timeout, so
  it should be skipped for offline accounts.
- Frontend: `AccountsCard.vue` (list/switch/add/remove),
  `MinecraftRequiredModal.vue` (dead-end when signed out),
  `helpers/auth.js` (thin Tauri wrappers), `App.vue` auth-reachability banner
  (informational only, not a launch gate).

## 3. Architecture

One account table, two account types. Offline accounts are real rows in
`minecraft_users` with `account_type = 'offline'` and NULL network
credentials. All selection, activation, and removal logic is unchanged; only
network-dependent operations branch on the type.

```
AccountsCard.vue ── create_offline_user(name) ─▶ minecraft_auth.rs ─▶ minecraft_users
      │                    │                              │  (account_type, nullable tokens)
      │                    ▼                              ▼
      │             validation + deterministic UUID   get_default_credential()
      │                                                    │ (no refresh when offline)
      ▼                                                    ▼
MinecraftRequiredModal ── Continue offline ──▶ run.rs ──▶ launcher/args.rs
 (new secondary path)      (active offline row)  (skip session join)  (offline args)
```

## 4. Data model & migration

Migration (new file, e.g.
`migrations/20261013000000_offline_accounts.sql`):

```sql
ALTER TABLE minecraft_users ADD COLUMN account_type TEXT NOT NULL DEFAULT 'microsoft';
```

- `account_type`: `'microsoft'` (default, existing rows) | `'offline'`.
- `access_token`, `refresh_token`, `expires` stay `NOT NULL`; offline rows
  store sentinel values (`''`, `''`, `0`). This deliberately avoids a table
  rebuild, which would drop the `AFTER UPDATE OF uuid ON minecraft_users`
  triggers owned by the skin-selector migration. All consumers branch on
  `account_type` and never read tokens for offline rows.
- Update `.sqlx` checked-query JSON files for every touched query (regenerate
  with `cargo sqlx prepare` against a migrated scratch DB).
- Validation of the migration: existing rows unchanged, new column defaults
  correctly, offline rows insert/select round-trip.

## 5. Backend (`packages/app-lib`)

### 5.1 `Credentials`

- Add `account_type` (enum `MinecraftAccountType { Microsoft, Offline }` with
  `#[serde(rename_all = "lowercase")]` / `#[sqlx(rename_all = "lowercase")]`
  matching the DB values `'microsoft'` / `'offline'`), surfaced in
  serialization so the frontend can badge offline rows.
- `is_offline()` helper.
- `refresh()`: early `Ok(())` when offline (never touches network).
- `online_profile*()`: return `None` immediately when offline (skip cache +
  Mojang fetch; avoids backoff pollution). `maybe_online_profile()` fallback
  covers consumers unchanged.
- `get_default_credential()`: return active offline credentials as-is without
  refresh attempts — this is what makes zero-network launch possible.
- `upsert()`: persist `account_type`; for offline rows write NULL tokens and
  a sentinel/NULL expiry; keep single-`active` semantics.
- `Serialize`: include `account_type`; profile hydration already degrades to
  the offline profile — no change needed.

### 5.2 New API functions (`api/minecraft_auth.rs` + Tauri command registration)

- `create_offline_user(name: String) -> Credentials`:
  1. Trim + validate name (see §5.4).
  2. Compute deterministic offline UUID (see §5.3).
  3. Case-insensitive uniqueness check on `(username)` and UUID collision
     check → `InputError("name already in use")`.
  4. Insert row (`account_type='offline'`, NULL tokens, `active=true`,
     deactivate others via existing `upsert` semantics) and return it.
- `rename_offline_user(uuid, new_name)`: Microsoft rows → `InputError`;
  offline rows → re-validate, recompute UUID (new identity), collision-check,
  delete old row + insert new row (PK is UUID), preserve `active` flag.
- Reuse `set_default_user`, `remove_user`, `get_users`, `get_default_user`
  unchanged (they operate on UUIDs, type-agnostic).
- New Tauri commands wired wherever `plugin:auth|*` commands are registered
  (check `apps/app/src-tauri` plugin registration for `auth`).

### 5.3 Offline UUID algorithm (must match vanilla)

Vanilla `UUID.nameUUIDFromBytes("OfflinePlayer:<name>".getBytes())`:

1. `digest = MD5_UTF8("OfflinePlayer:" + name)` (16 bytes, exact case).
2. Set version bits: `digest[6] = (digest[6] & 0x0f) | 0x30` (v3).
3. Set variant bits: `digest[8] = (digest[8] & 0x3f) | 0x80`.
4. Interpret as big-endian UUID.

Do NOT use `Uuid::new_v3(namespace, name)` — it prefixes a namespace UUID
and diverges from vanilla saves. Add `md-5` (or existing digest crate) if not
already available; `sha2` is present, MD5 likely needs a new dep — prefer
`md5` crate.

Known-vector tests: pin exact expected UUID strings generated with a
reference implementation and verified against a vanilla-launcher-produced
offline UUID before merging (e.g. create the same name in the vanilla
launcher's offline mode and compare).

### 5.4 Name validation

- Rules: length 3–16, charset `[A-Za-z0-9_]` only (same as Mojang usernames so
  worlds, chat, and offline-mode servers behave). Trim whitespace; reject
  empty; case-insensitive uniqueness (`LOWER(username)`).
- Error type: `ErrorKind::InputError` with a human message; frontend mirrors
  the regex live for fast feedback.

### 5.5 Launcher args (`launcher/args.rs`)

Branch on `credentials.is_offline()` in `get_minecraft_arguments` /
`parse_minecraft_argument`:

- `accessToken / auth_access_token / auth_session` → `"0"`.
- `auth_uuid / uuid` → offline UUID (hyphenless `.simple()` as today).
- `user_type` → `"legacy"` (default; verify against vanilla 1.21 client in
  manual testing — fall back to `"mojang"` if the client rejects `"legacy"`).
- `auth_xuid` → `"0"`, `user_properties` → `"{}"`, `clientid` unchanged.
- Username from the offline profile name.

### 5.6 Launch path (`api/instance/run.rs`)

- `run()` unchanged (offline default account satisfies the
  `NoCredentialsError` gate).
- Skip the Mojang session-server `join` + analytics best-effort block when
  `credentials.is_offline()` (avoids pointless timeout with no network).
- `flush_pending_skin_change()` — verify it is a safe no-op when offline;
  if it errors without credentials/network, skip for offline too.

### 5.7 Skins (`api/minecraft_skins.rs`)

- All entry points currently `get_default_credential()`. For offline
  credentials: return default/empty skin state (or a dedicated
  `InputError("skins require a Microsoft account")` for mutating calls —
  prefer the error for mutations, defaults for reads). No new skin pipeline.
- Frontend disables editing when the active account is offline (see §6).

## 6. Frontend (`apps/app-frontend`)

### 6.1 `helpers/auth.js`

Add thin wrappers: `create_offline_user(name)`,
`rename_offline_user(uuid, newName)` invoking the new Tauri commands.

### 6.2 `AccountsCard.vue`

- "Add account" area becomes two actions: "Sign in to Microsoft" (existing
  flow) + "Play offline" (new name dialog).
- Name dialog: text input with live regex validation + error text, submit
  disabled until valid; on success `setAccount(newProfile)` + `refreshValues()`.
- Offline rows: "Offline" badge next to the name; avatar = local Steve head
  asset (skip `mc-heads.net` lookups for offline UUIDs); rename affordance
  (pencil → inline input → `rename_offline_user`); existing remove flow reused.
- `MinecraftCredential` type gains `account_type: 'microsoft' | 'offline'`.

### 6.3 `MinecraftRequiredModal.vue`

- Add secondary "Continue offline" button: creates (or selects, if one exists)
  an offline identity, sets it default, refreshes `AccountsCard`, hides modal.
- Copy tweak: description notes that servers with online-mode enabled will
  reject offline sessions.

### 6.4 Skins page + sidebar

- Skins page: when active account is offline, show the existing signed-out
  notice variant ("Sign in to your Minecraft account to save and apply
  skins!") with editing disabled. No fetch attempts.
- Sidebar "Playing as": unchanged (reads `profile.name`).

### 6.5 i18n

- New message IDs only (all with English `defaultMessage`, letting other
  locales fall back): `minecraft-account.play-offline`,
  `minecraft-account.offline-badge`, `minecraft-account.create-offline-*`
  (dialog header, name label, validation errors, name-in-use),
  `minecraft-account.rename-*`, `minecraft-required.continue-offline`,
  `minecraft-required.offline-note`.
- Do not hand-edit other locale files; Crowdin handles translations.

## 7. Error handling

| Situation | Behavior |
|---|---|
| Launch, no accounts at all | `MinecraftRequiredModal` as today, now with "Continue offline" escape hatch |
| Launch, active account offline, no network | Launches; session join skipped; no error. Single-player, LAN, and `online-mode=false` servers all work |
| Join `online-mode=false` server with offline account | Works normally — no auth check to fail; UUID is the deterministic offline UUID for that name |
| Launch, active MS account expired, no network | Existing behavior (uses stale creds if connect/timeout; `maybe_online` fallback) — unchanged |
| Online server rejects offline session | Game/server shows its own auth error; launcher does not intercept |
| Duplicate offline name (case-insensitive) or UUID collision | `InputError`, surfaced inline in the dialog |
| Invalid name | `InputError`, inline validation + backend re-check |
| Rename Microsoft account | `InputError("only offline accounts can be renamed")` |
| Skin mutation with offline account | `InputError("skins require a Microsoft account")`, frontend pre-disables |

`use-error.js` routing: no new modal; `InputError`s go to the standard error
modal / inline form errors.

## 8. Testing

Unit (Rust):

- Offline UUID vectors (pinned against vanilla reference).
- Name validation accept/reject table.
- `refresh()` no-op offline (no HTTP attempts — assert via mock or by
  calling with no network in test env).
- Launcher args snapshot: offline (`"0"`, `"legacy"`, offline UUID) vs
  Microsoft (`msa`, real token).
- `create_offline_user` duplicate (incl. case-insensitive) → `InputError`.

Manual:

1. Fresh profile → "Play offline" as `Alex_01` → disable network → launch
   vanilla 1.21 single-player world → moves/saves work.
2. Re-enable network → MS sign-in still works; switch active between MS and
   offline; sidebar updates.
3. Rename offline `Alex_01` → `Alex_02` → new UUID (verify world list
   identity change); old name re-addable.
4. Remove accounts until none → launch → modal offers "Continue offline".
5. Attempt join of an `online-mode=true` server with offline account →
   rejected by server (expected), launcher shows no false success.
6. Skins page with offline active → disabled state, no errors.

Regression: `pnpm prepr:frontend:app` (or at minimum the app-frontend
checks), `cargo test -p theseus` (app-lib) or workspace-equivalent per
`AGENTS.md` backend instructions; verify `.sqlx` files regenerated
(`cargo sqlx prepare` if the project uses it).

## 9. Out of scope

- Offline skins/capes/textures.
- Migrating worlds/saves between identities.
- Any bypass of third-party server authentication.
- Demo-mode (`--demo`) support.
- Changing Mojang/MSA login itself.

## 10. Risks & mitigations

- `user_type` value (`legacy` vs alternatives): verify by launching vanilla
  1.21 offline; keep it a one-line constant so it can flip without redesign.
- SQLite `NOT NULL → nullable` migration: use rename-copy-drop pattern and
  test on a copy of a real DB with existing MS rows.
- MD5 dependency: tiny, well-known crate; alternatively implement via
  existing crypto deps if MD5 already transitively available.
- Name/UUID collisions after rename: pre-check + PK conflict handling with a
  clean `InputError`, never silent overwrite.

## 11. Implementation order (for the plan)

1. Migration + `Credentials`/`account_type` + validation + UUID (+ unit tests).
2. `create/rename_offline_user` API + Tauri commands.
3. Launcher args branch + session-join skip + skins guards.
4. Frontend: `auth.js`, `AccountsCard`, `MinecraftRequiredModal`, skins
   gating, i18n strings.
5. Manual offline E2E + regression checks (`prepr`, Rust tests).
