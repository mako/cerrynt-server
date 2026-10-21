# Cerrynt API v1 (draft)

Base path: `/api/v1`. JSON in, JSON out. This document is the contract between `cerrynt-server` and all clients. Update it **before** changing behaviour.

## Conventions

- **Auth:** `Authorization: Bearer <token>`. Tokens are opaque, per device, revocable.
- **Timestamps:** ISO 8601, UTC (`2026-10-02T12:00:00Z`).
- **IDs:** opaque strings in responses (clients must not assume integers).
- **Pagination:** cursor based. Responses contain `next_cursor` (`null` on the last page). Request with `?cursor=...&limit=50` (max 100).
- **Errors:**

```json
{ "error": { "code": "feed_limit_reached", "message": "Free plan allows 2 feeds.", "details": {} } }
```

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `bad_request` | malformed request or body, or an invalid query parameter; `details.param` names the parameter |
| 401 | `unauthorized` | missing/invalid/revoked token |
| 401 | `invalid_credentials` | wrong email or password |
| 403 | `feed_limit_reached` | plan limit exceeded; `details` has `limit` and `plan` |
| 404 | `not_found` | resource missing or not yours |
| 422 | `validation_failed` | `details` holds field errors |
| 422 | `invalid_feed_url` | malformed, not http/https, too long, or the response is not a feed |
| 422 | `feed_unreachable` | could not fetch the feed (this includes hosts that are not allowed) |
| 429 | `rate_limited` | too many requests, or too many feed fetches in progress; retry after `Retry-After` seconds |

## Auth

### `POST /registrations`
```json
{ "email": "a@example.com", "password": "..." }
```
`201` → `{ "user": User }`

### `POST /sessions`
`device_name` is required (max 100 characters).
```json
{ "email": "a@example.com", "password": "...", "device_name": "laptop-cli" }
```
`201` → `{ "token": "<shown once>", "user": User }`

### `DELETE /session`
Revokes the current token. `204`.

### `GET /me`
`200` → `{ "user": User }`

`User`:
```json
{ "id": "...", "email": "...", "plan": "free",
  "limits": { "max_feeds": 2 }, "usage": { "feeds": 1 } }
```

## Subscriptions

### `GET /subscriptions`
`200` → `{ "subscriptions": [Subscription] }` (no pagination; bounded by plan).

### `POST /subscriptions`
```json
{ "url": "https://example.com/feed.xml" }
```
`201` → `{ "subscription": Subscription }`. Errors: `feed_limit_reached`, `invalid_feed_url`, `feed_unreachable`. Subscribing to an already subscribed feed returns `200` with the existing subscription.

### `DELETE /subscriptions/:id`
`204`.

`Subscription`:
```json
{ "id": "...", "title": "Example Blog", "custom_title": null,
  "url": "https://example.com/feed.xml", "site_url": "https://example.com",
  "unread_count": 12, "status": "active", "last_fetched_at": "..." }
```

## Entries

### `GET /entries`
Query: `subscription_id`, `unread` (`true` or `false`; absent = no filter), `starred` (`true` or `false`; absent = no filter), `cursor`, `limit` (default 50; above 100 is clamped to 100; not an integer or `< 1` returns `400`). Ordered by `published_at` desc, `id` desc. All entries currently stored for a subscribed feed are listed, including those published before the subscription.
`200` → `{ "entries": [EntrySummary], "next_cursor": "..." }`. Errors: `bad_request` (invalid `cursor`, `limit`, `unread`, or `starred`), `not_found` (unknown or unowned `subscription_id`).

### `GET /entries/:id`
`200` → `{ "entry": Entry }` (includes sanitized `summary` and `content` HTML)

`EntrySummary`:
```json
{ "id": "...", "subscription_id": "...", "title": "...", "author": "...",
  "url": "...", "published_at": "...",
  "read": false, "starred": false }
```
`Entry` = `EntrySummary` + `"summary": "<p>...</p>", "content": "<p>...</p>"`.

`summary` and `content` (returned by `GET /entries/:id`) are sanitized HTML (fixed tag allow-list, absolute http(s)/mailto links with rel=nofollow noopener noreferrer, no scripts, styles, forms or embeds); every other text field is plain text and must be escaped by clients.

### `PATCH /entries/:id/state`
```json
{ "read": true, "starred": false }
```
At least one of `read` / `starred` is required; each must be a JSON boolean (`true` sets the flag, `false` clears it). Unknown extra keys are ignored. Idempotent: repeating a request changes nothing.
`200` → `{ "entry": EntrySummary }`. Errors: `bad_request` (`details.param` is `state` when both fields are absent, or `read` / `starred` when a value is not a boolean, including null), `not_found` (unknown or not yours).

### `POST /entries/mark_read`
```json
{ "subscription_id": "...", "before": "2026-10-02T12:00:00Z" }
```
At least one of `subscription_id` / `before` is required. `before` is an ISO 8601 timestamp with a zone; entries with `published_at <= before` match. Marks the matching unread entries of your subscriptions as read; `marked` counts only entries that changed from unread to read (to mark everything, send `before` = now).
`200` → `{ "marked": 37 }`. Errors: `bad_request` (`details.param` is `before` when invalid or when both parameters are absent), `not_found` (unknown or not yours `subscription_id`).

## Sync

### `GET /sync?since=<cursor>`
First sync: omit `since`. A present `since` must be a cursor returned by a previous sync response; an empty value is invalid. Every response contains the complete current `subscriptions` list and one page (up to 100) of `entries`, oldest change first:
```json
{ "subscriptions": [Subscription],
  "entries": [EntrySummary],
  "cursor": "opaque-string",
  "has_more": false }
```
An entry is sent when it is new or changed, when its read/starred state changed, or when you subscribed (or re-subscribed) to its feed; entries of feeds you do not follow are never sent. The same entry can be sent more than once (for example when it changes while you page): clients must upsert by `id`.
Clients store `cursor` and pass it as `since` on the next request; repeat while `has_more` is true. When `entries` is empty the returned `cursor` stays valid and no change is ever skipped.
`subscriptions` is authoritative: a subscription the client knows that is absent from it, together with its local entries, has been removed. Entries deleted by server-side retention are not reported. `unread_count` values describe the moment of the response. Conflict rule: last write wins per entry state.
Errors: `bad_request` (`details.param` is `since` when `since` is malformed, tampered with, or empty).

## OPML

- `POST /opml/import` (`multipart/form-data`, field `file`) → `{ "imported": 5, "skipped": 2, "errors": [] }` (plan limits apply).
- `GET /opml/export` → `application/xml`.

## Open questions

- Maximum number of entries kept per feed (retention).
