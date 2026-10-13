# Offline Play Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users add offline Minecraft accounts with a custom name and launch the game with zero network access.

**Architecture:** First-class offline rows in `minecraft_users` (`account_type`, nullable tokens); network paths early-return for offline; launcher emits vanilla offline-mode args; frontend adds a "Play offline" path next to Microsoft sign-in.

**Tech Stack:** Rust (`theseus` app-lib, sqlx/sqlite, `md5` workspace crate), Tauri commands (`apps/app/src/api/auth.rs`), Vue 3 frontend (`apps/app-frontend`).

**Spec:** `docs/superpowers/specs/2026-10-13-offline-play-design.md`

## Global Constraints

- Indentation: TAB everywhere, never spaces.
- No git worktrees; feature branch `feature/offline-play` (already checked out).
- Name rules: length 3–16, charset `[A-Za-z0-9_]` only, trim whitespace, case-insensitive uniqueness.
- Offline UUID = MD5(`"OfflinePlayer:<name>"`) with v3/variant bits (spec §5.3). Do NOT use `Uuid::new_v3(namespace, …)`.
- `user_type` for offline launches: `"legacy"` (verify against vanilla 1.21; one-line constant).
- New i18n strings need English `defaultMessage` only; never hand-edit other locale files.
- sqlx uses checked queries (`.sqlx/*.json`); after changing queries run `cargo sqlx prepare` with `DATABASE_URL` pointing at a migrated sqlite file (turbo passes through `SQLX_OFFLINE`/`DATABASE_URL`).

## Review Focus

- Name with leading/trailing spaces or mixed case (`"  Alex_01 "`): trimmed for validation/UUID, uniqueness checked case-insensitively.
- Re-adding a previously removed offline name: deterministic UUID must reproduce the identical UUID.
- Active offline account + expired/unreachable Microsoft tokens elsewhere: launch still succeeds, no refresh attempted.
- Duplicate offline name differing only by case (`alex_01` vs `ALEX_01`): rejected with `InputError`.
- Offline account selected on Skins page: no network fetch attempted, editing disabled with explanatory copy.

---

### Task 1: Migration + UUID + validation (+ pure unit tests)

**Files:**
- Create: `packages/app-lib/migrations/20261013000000_offline_accounts.sql`
- Modify: `packages/app-lib/Cargo.toml` (add `md5 = { workspace = true }`)
- Modify: `packages/app-lib/src/state/minecraft_auth.rs` (add `MinecraftAccountType`, `offline_uuid()`, `validate_offline_username()`)
- Test: inline `#[cfg(test)]` module in `minecraft_auth.rs` (follows existing `launcher/hooks.rs:120` pattern)

**Interfaces:**
- Consumes: `md5 = "0.8.0"` from workspace `Cargo.toml` (already present, line 139).
- Produces: `pub enum MinecraftAccountType { Microsoft, Offline }` (serde + sqlx `rename_all = "lowercase"`); `pub fn offline_uuid(name: &str) -> Uuid`; `pub fn validate_offline_username(name: &str) -> crate::Result<String>` returning the trimmed name or `ErrorKind::InputError`.

- [ ] **Step 1: Write failing tests** in a new `#[cfg(test)] mod offline_tests` in `state/minecraft_auth.rs`: `offline_uuid_is_deterministic` (same name twice → equal), `offline_uuid_differs_per_name`, `offline_uuid_version_is_3` (assert `uuid.get_version() == Some(Version::Mac)`), `username_validation_accepts_table` (`Alex_01`, `abc`, 16-char name → trimmed value), `username_validation_rejects_table` (`ab`, 17 chars, `has space`, `dash-name`, empty, `"  "` → `InputError`). UUID-vs-vanilla vector test: name the test `offline_uuid_matches_vanilla_reference` with a `todo!()` body pinned to verifying against a real vanilla offline UUID before merge.
- [ ] **Step 2: Run to verify failure.** Run: `cargo test -p theseus offline_` Expected: FAIL (functions not defined).
- [ ] **Step 3: Add migration** `20261013000000_offline_accounts.sql`: `ALTER TABLE minecraft_users ADD COLUMN account_type TEXT NOT NULL DEFAULT 'microsoft'` plus nullable conversion of `access_token`/`refresh_token`/`expires` via rename-copy-drop preserving all rows (spec §4).
- [ ] **Step 4: Implement** `MinecraftAccountType`, `offline_uuid()`, `validate_offline_username()` per spec §§5.3–5.4 (MD5 bytes → set `digest[6] = (digest[6] & 0x0f) | 0x30`, `digest[8] = (digest[8] & 0x3f) | 0x80` → `Uuid::from_bytes`). Add `md5 = { workspace = true }` to app-lib deps.
- [ ] **Step 5: Run tests.** Run: `cargo test -p theseus offline_` Expected: PASS (except the `todo!()` reference test, which must be resolved with a real vanilla vector before merge — see Review Focus line 2 for the re-add invariant it pins).
- [ ] **Step 6: Commit.** `git add packages/app-lib/... && git commit -m "feat: offline account UUID, validation, and migration"`

### Task 2: Credentials offline behavior + create/rename API (+ DB test)

**Files:**
- Modify: `packages/app-lib/src/state/minecraft_auth.rs` (`Credentials.account_type`, `is_offline()`, refresh/profile early-returns, `create_offline_user`, `rename_offline_user`, `upsert` persistence, `Serialize` field)
- Modify: `packages/app-lib/src/api/minecraft_auth.rs` (public wrappers)
- Modify: `.sqlx/*.json` (regenerated via `cargo sqlx prepare`)
- Test: `#[tokio::test]` DB test in `minecraft_auth.rs` using a temp `SqlitePool` + `sqlx::migrate!()` (same call as `state/db.rs:38`)

**Interfaces:**
- Consumes: Task 1 (`MinecraftAccountType`, `offline_uuid`, `validate_offline_username`).
- Produces: `impl Credentials { pub fn is_offline(&self) -> bool }`; `pub async fn create_offline_user(name: &str, exec) -> crate::Result<Credentials>`; `pub async fn rename_offline_user(uuid: Uuid, new_name: &str, exec) -> crate::Result<Credentials>`; API wrappers `minecraft_auth::create_offline_user(name)`, `minecraft_auth::rename_offline_user(uuid, new_name)` resolving `State::get()` pool like `get_default_user()` does (`api/minecraft_auth.rs:51-55`).

- [ ] **Step 1: Write failing DB test** `offline_account_crud_roundtrip`: migrate temp DB → `create_offline_user("Alex_01")` → assert `is_offline()`, deterministic UUID, `active=true` → `get_default_credential()` returns it without network (test env has no network reliance; assert Ok) → duplicate `create_offline_user("alex_01")` → `InputError` → `rename_offline_user(uuid, "Alex_02")` → new deterministic UUID, old row gone → remove + re-add `"Alex_02"` → identical UUID to the renamed one → `rename` on a Microsoft row → `InputError`.
- [ ] **Step 2: Run to verify failure.** Run: `cargo test -p theseus offline_account_crud_roundtrip` Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** `Credentials.account_type` field + `is_offline()`; `refresh()` early-`Ok(())` when offline; `online_profile_with_cache_intent()` early-`None` when offline; `get_default_credential()` returns offline rows without refresh; `upsert()` writes `account_type` + NULL tokens/expiry for offline; `Serialize` adds `account_type`; `create_offline_user`/`rename_offline_user` per spec §5.2 (rename: delete old-UUID row, insert new-UUID row, preserve `active`).
- [ ] **Step 4: Regenerate sqlx data.** Run migrations on a scratch sqlite file, then `DATABASE_URL=sqlite:<scratch> cargo sqlx prepare -- --lib` (from `packages/app-lib`); verify `git status` shows updated `.sqlx/*.json` only for touched queries.
- [ ] **Step 5: Run tests.** Run: `cargo test -p theseus minecraft_auth` Expected: PASS, no network access attempted (offline paths never construct HTTP requests).
- [ ] **Step 6: Commit.** `git commit -m "feat: offline credentials storage and account management"`

### Task 3: Launcher + launch path + Tauri commands

**Files:**
- Modify: `packages/app-lib/src/launcher/args.rs` (offline branch in `get_minecraft_arguments`/`parse_minecraft_argument`)
- Modify: `packages/app-lib/src/api/instance/run.rs` (skip session-server join when offline)
- Modify: `packages/app-lib/src/api/minecraft_skins.rs` (offline guards: reads → defaults, mutations → `InputError`)
- Modify: `apps/app/src/api/auth.rs` (register `create_offline_user`, `rename_offline_user` commands)
- Test: inline unit test for offline args snapshot

**Interfaces:**
- Consumes: Task 2 (`is_offline()`, `Credentials.account_type`).
- Produces: Tauri commands `plugin:auth|create_offline_user { name }`, `plugin:auth|rename_offline_user { uuid, new_name }`; launcher constant for offline `user_type`.

- [ ] **Step 1: Write failing test** `offline_launcher_args_snapshot`: construct a `Credentials` with an offline profile (`access_token: String::new()`) → `get_minecraft_arguments(...)` with a minimal `arguments: None` path or direct `parse_minecraft_argument` call → assert `accessToken`/`auth_session` = `"0"`, `user_type` = `"legacy"`, uuid matches offline UUID hyphenless. Microsoft control case asserts `user_type = "msa"`.
- [ ] **Step 2: Run to verify failure.** Run: `cargo test -p theseus offline_launcher_args_snapshot` Expected: FAIL.
- [ ] **Step 3: Implement launcher branch** per spec §5.5 (offline: token `"0"`, `user_type` const `"legacy"`, offline UUID, `auth_xuid "0"`, `user_properties "{}"`).
- [ ] **Step 4: Implement run.rs skip**: `if credentials.is_offline()` bypass the session-server join/analytics block (`run.rs:247-292`); verify `flush_pending_skin_change()` is safe offline or skip it too.
- [ ] **Step 5: Implement skins guards** per spec §5.7 and register the two Tauri commands in `apps/app/src/api/auth.rs` `invoke_handler!` + thin `#[tauri::command]` fns delegating to `minecraft_auth::*`.
- [ ] **Step 6: Run tests + clippy.** Run: `cargo test -p theseus` then `cargo clippy -p theseus` Expected: all PASS, no new warnings.
- [ ] **Step 7: Commit.** `git commit -m "feat: offline launch args, session skip, and auth commands"`

### Task 4: Frontend accounts + modals + skins gating

**Files:**
- Modify: `apps/app-frontend/src/helpers/auth.js` (add `create_offline_user`, `rename_offline_user` wrappers)
- Modify: `apps/app-frontend/src/components/ui/AccountsCard.vue` (Play-offline dialog, offline badge, Steve avatar for offline, rename UI, extended `MinecraftCredential` type)
- Modify: `apps/app-frontend/src/components/ui/minecraft-required-modal/MinecraftRequiredModal.vue` (Continue-offline path)
- Modify: `apps/app-frontend/src/pages/Skins.vue` (disable editing when active account is offline)
- Test: manual checklist (no frontend unit harness in repo); `pnpm prepr:frontend:app` from root.

**Interfaces:**
- Consumes: Task 3 Tauri commands (`plugin:auth|create_offline_user`, `plugin:auth|rename_offline_user`); `Credentials.account_type` in serialized users.

- [ ] **Step 1: Add `auth.js` wrappers** `create_offline_user(name)`, `rename_offline_user(uuid, new_name)` invoking `plugin:auth|create_offline_user { name }` / `plugin:auth|rename_offline_user { uuid, new_name }`, mirroring existing `invoke('plugin:auth|…')` style.
- [ ] **Step 2: Implement AccountsCard changes** per spec §6.2: two-action add area, name dialog with live `/^[A-Za-z0-9_]{3,16}$/` validation, offline badge, local Steve-head avatar for offline rows, inline rename, `account_type` in credential type.
- [ ] **Step 3: Implement RequiredModal Continue-offline** per spec §6.3 (create-or-select offline identity → `set_default_user` → `refreshValues()` → hide) + offline note copy.
- [ ] **Step 4: Implement Skins gating**: active account `account_type === 'offline'` → existing signed-out notice + disabled editing, no fetch attempts.
- [ ] **Step 5: Verify.** Run from root: `pnpm prepr:frontend:app` Expected: PASS with no new lint/type errors. Manual click-through with network on: add offline `Alex_01`, switch default MS ↔ offline, rename, remove.
- [ ] **Step 6: Commit.** `git commit -m "feat: offline account UI and skins gating"`

### Task 5: Offline E2E + regression + PR

**Files:** none (verification only).

- [ ] **Step 1: Full offline E2E** per spec §8 manual list with OS network disabled: fresh offline `Alex_01` → launch vanilla 1.21 single-player → world save works → join an `online-mode=false` test server → works → `online-mode=true` server → rejected by server (expected, no launcher false-success). Re-enable network: MS sign-in unaffected; sidebar "Playing as" correct in both modes.
- [ ] **Step 2: Regression.** Run: `cargo test -p theseus` and `pnpm prepr:frontend:app` (root). If touching shared lib types, also `pnpm prepr:frontend:lib`. Expected: all green.
- [ ] **Step 3: Push + open PR** with spec link and E2E evidence; ensure the vanilla-UUID reference check (Task 1 `todo!()`) is resolved before marking ready.
