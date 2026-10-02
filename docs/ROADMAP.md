# Cerrynt Server – Roadmap

Rails backend and source of truth for Cerrynt. Clients (the Go TUI in `cerrynt-cli`, later web/mobile) talk to it through the versioned JSON API described in [`API.md`](API.md).

## Principles

- **Contract first.** `docs/API.md` is the contract. Change it before changing behaviour.
- **Thin vertical slices.** Get register → add feed → fetch → read entries working end to end before polishing anything.
- **Small scope.** Anything not listed below is out of scope until the MVP is live.
- **Small commits, one task per branch**, each with tests.
- **Public repo hygiene.** No secrets in git. Credentials via Rails credentials or environment variables.

### Out of scope for the MVP

Full-text search, recommendations, social features, mobile clients, real payments (Stripe test mode only), complex conflict resolution in sync, multi-region anything.

## Target data model

| Table | Key columns | Notes |
|---|---|---|
| `users` | `email` (citext, unique), `password_digest`, `plan` (`free`/`pro`, default `free`) | feed limit derived from `plan` |
| `api_tokens` | `user_id`, `token_digest` (unique), `name` (device), `last_used_at`, `revoked_at` | opaque token, only the digest is stored |
| `feeds` | `url` (normalized, unique), `title`, `site_url`, `etag`, `last_modified`, `last_fetched_at`, `last_success_at`, `consecutive_failures`, `next_fetch_at`, `status` | global, shared between users |
| `subscriptions` | `user_id`, `feed_id`, `custom_title` | unique `[user_id, feed_id]` |
| `entries` | `feed_id`, `guid`, `url`, `title`, `author`, `summary`, `content`, `published_at` | unique `[feed_id, guid]`, index on `[feed_id, published_at]` |
| `entry_states` | `user_id`, `entry_id`, `read_at`, `starred_at` | unique `[user_id, entry_id]`, index on `[user_id, updated_at]` for sync |

Design notes:

- Feeds and entries are **shared**; only subscriptions and entry states are per user. If many users follow the same feed, it is fetched once.
- No `entry_states` row means "unread, not starred".
- Plan limits: free = 2 feeds, pro = higher (configurable constant).

## Phase R0 – Foundation

- [x] **R0.1** Upgrade to the latest stable Ruby and Rails; review framework defaults and config diffs.
- [ ] **R0.2** Review the already generated (uncommitted) models and migrations against the target model above; fix discrepancies.
- [x] **R0.3** Confirm SQLite as the MVP database (no citext; normalize emails in the model). Avoid SQLite-specific features so a later PostgreSQL move stays possible.
- [x] **R0.4** Test framework chosen and configured (one of Minitest/RSpec, not both), factories or fixtures.
- [ ] **R0.5** GitHub Actions: tests, RuboCop (`rubocop-rails-omakase` or equivalent), Brakeman, bundler-audit.
- [ ] **R0.6** `AGENTS.md` with conventions; README skeleton.

**Done when:** CI is green on an empty-but-real app with the full schema migrated.

## Phase R1 – Auth

- [ ] **R1.1** `POST /api/v1/registrations` (email + password, validations).
- [ ] **R1.2** `POST /api/v1/sessions` returns an opaque token per device; `DELETE /api/v1/session` revokes it.
- [ ] **R1.3** Token authentication via `Authorization: Bearer`, `last_used_at` updated (throttled).
- [ ] **R1.4** `GET /api/v1/me` returns user, plan and limits.
- [ ] **R1.5** Rate limiting on registration and login (Rails `rate_limit` and/or Rack::Attack).

**Done when:** request specs cover happy paths, wrong password, revoked token, rate limit.

## Phase R2 – Feeds and subscriptions

- [ ] **R2.1** `Feed` URL normalization (scheme, host case, trailing slash, fragments).
- [ ] **R2.2** `POST /api/v1/subscriptions` with `url`: validate, find-or-create feed, enforce plan limit (`feed_limit_reached`).
- [ ] **R2.3** `GET /api/v1/subscriptions`, `DELETE /api/v1/subscriptions/:id`.
- [ ] **R2.4** Safe fetcher service (see R3) used for the first fetch on subscribe; feed discovery from an HTML page URL is optional.

## Phase R3 – Fetching

- [ ] **R3.1** Fetcher: `Net::HTTP`/Faraday with timeouts, max body size, redirect limit, `User-Agent`.
- [ ] **R3.2** **SSRF protection:** resolve the host and reject loopback, private, link-local (including `169.254.169.254`) and other reserved ranges; re-check after redirects; only `http`/`https`.
- [ ] **R3.3** Parse with `feedjira` (or similar); upsert entries by `[feed_id, guid]`; fall back to URL/hash when `guid` is missing.
- [ ] **R3.4** Conditional GET (`ETag`, `Last-Modified`), `next_fetch_at` scheduling, exponential backoff on failures, feed `status` (`active`/`failing`/`dead`).
- [ ] **R3.5** Solid Queue recurring job that fetches due feeds in small batches.
- [ ] **R3.6** Sanitize entry HTML (Loofah/`sanitize`), retention policy for old entries.

**Done when:** tests cover malicious URLs, redirects to private IPs, oversized responses, malformed feeds, duplicate guids.

## Phase R4 – Reading and sync

- [ ] **R4.1** `GET /api/v1/entries` with `feed_id`, `unread`, `starred`, cursor pagination.
- [ ] **R4.2** `GET /api/v1/entries/:id` (full content).
- [ ] **R4.3** `PATCH /api/v1/entries/:id/state` (read/starred), idempotent; `POST /api/v1/entries/mark_read`.
- [ ] **R4.4** `GET /api/v1/sync?since=` returns subscriptions, new/changed entries and changed states since the cursor.
- [ ] **R4.5** OPML import and export.
- [ ] **R4.6** Unread counts per subscription (cheap query, no N+1).

## Phase R5 – Plans and limits

- [ ] **R5.1** Central `Plan` object (limits per plan) used everywhere; no scattered magic numbers.
- [ ] **R5.2** Clear error contract for limit violations (documented in `API.md`).
- [ ] **R5.3** Billing decision: Stripe test mode vs. Merchant of Record (Paddle / Lemon Squeezy); VAT implications for a UK seller. For the portfolio demo, test mode is enough.
- [ ] **R5.4** (Optional) Checkout and webhook handling that flips `plan`.

## Phase R6 – Production on EC2

- [ ] **R6.1** Kamal 2 deploy to the EC2 instance; TLS via the built-in proxy; domain.
- [ ] **R6.2** Production config: logging, error reporting, `force_ssl`, host authorization.
- [ ] **R6.3** Back up the SQLite databases (Litestream or scheduled sqlite3 .backup to S3), keep storage/ as a persistent Kamal volume, test a restore once.
- [ ] **R6.4** Uptime check and basic alerting.
- [ ] **R6.5** Abuse protection for a public instance: signup cap or invite code, Rack::Attack, per-user entry/feed limits.
- [ ] **R6.6** Public **demo account** documented in the README.

## Phase R7 – Polish

- [ ] **R7.1** README: what it is, architecture diagram, how to run locally, how to try the demo, API link.
- [ ] **R7.2** Short ADRs in `docs/decisions/` (opaque tokens vs. JWT, shared feeds, sync strategy, plan limits).
- [ ] **R7.3** CI badges, seed data for local development.

## Later

Web client (Hotwire) in the same app, then Android and iOS clients against the same API.

## Milestones (shared with `cerrynt-cli`)

| Milestone | Server | CLI |
|---|---|---|
| **M0** Contract | `API.md`, `AGENTS.md` | `AGENTS.md` aligned |
| **M1** Walking skeleton | R0, R1, R2, R3 (basic), R4.1–R4.2 | G0–G3 |
| **M2** Sync | R4.3–R4.6 | G4 |
| **M3** Live | R3 (full), R5, R6 | G5 |
| **M4** Polish | R7 | G6 |
