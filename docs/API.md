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
| 401 | `unauthorized` | missing/invalid/revoked token |
| 403 | `feed_limit_reached` | plan limit exceeded; `details` has `limit` and `plan` |
| 404 | `not_found` | resource missing or not yours |
| 422 | `validation_failed` | `details` holds field errors |
| 422 | `invalid_feed_url` | not http/https, blocked address, or not a feed |
| 422 | `feed_unreachable` | could not fetch the feed |
| 429 | `rate_limited` | `Retry-After` header set |

## Auth

### `POST /registrations`
```json
{ "email": "a@example.com", "password": "..." }
```
`201` → `{ "user": User }`

### `POST /sessions`
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
Query: `subscription_id`, `unread=true`, `starred=true`, `cursor`, `limit`. Ordered by `published_at` desc.
`200` → `{ "entries": [EntrySummary], "next_cursor": "..." }`

### `GET /entries/:id`
`200` → `{ "entry": Entry }` (includes sanitized `content` HTML)

`EntrySummary`:
```json
{ "id": "...", "subscription_id": "...", "title": "...", "author": "...",
  "url": "...", "summary": "...", "published_at": "...",
  "read": false, "starred": false }
```
`Entry` = `EntrySummary` + `"content": "<p>...</p>"`.

### `PATCH /entries/:id/state`
```json
{ "read": true, "starred": false }
```
Either field optional. Idempotent. `200` → `{ "entry": EntrySummary }`

### `POST /entries/mark_read`
```json
{ "subscription_id": "...", "before": "2026-10-02T12:00:00Z" }
```
Marks matching entries as read. `200` → `{ "marked": 37 }`

## Sync

### `GET /sync?since=<cursor>`
First sync: omit `since`. Returns everything changed after the cursor:
```json
{ "subscriptions": [Subscription],
  "entries": [EntrySummary],
  "cursor": "opaque-string",
  "has_more": false }
```
Clients store `cursor` and pass it next time; repeat while `has_more` is true. Conflict rule: **last write wins** per entry state.

## OPML

- `POST /opml/import` (`multipart/form-data`, field `file`) → `{ "imported": 5, "skipped": 2, "errors": [] }` (plan limits apply).
- `GET /opml/export` → `application/xml`.

## Open questions

- Should `GET /entries` list entries older than the subscription date, or only newer ones?
- Maximum number of entries kept per feed (retention).
