# Cerrynt API

Backend API for an RSS/Atom reader - manages feed subscriptions and read status via a JSON API. [`cerrynt-cli`](https://github.com/mako/cerrynt-cli) (a Go TUI client) consumes this API.

## Tech stack

- Ruby 3.4.10, Rails 8 (API-only mode)
- SQLite (Rails 8 default, [Litestream](https://litestream.io/)-compatible backups)
- [Solid Queue](https://github.com/rails/solid_queue) - background jobs (feed fetching), no separate Redis needed
- [Feedjira](https://github.com/feedjira/feedjira) - RSS/Atom parsing
- [Alba](https://github.com/okuramasafumi/alba) - JSON serialization
- [Pagy](https://github.com/ddnexus/pagy) - pagination
- RSpec, FactoryBot, WebMock/VCR - testing

## Prerequisites

- [mise](https://mise.jdx.dev/) for Ruby version management

```bash
mise install
```

(The Ruby version is pinned in `.mise.toml`.)

## Setup

```bash
bundle install
bin/rails db:setup       # creates the database, runs migrations
```

## Seed data (creating a development user)

The seed creates a user and prints out the corresponding API token, so you can test the endpoints.

```bash
SEED_USER_EMAIL="you@example.com" SEED_USER_PASSWORD="some-password" bin/rails db:seed
```

The output includes the `api_token`, which you need to send in the `Authorization: Bearer <token>` header on subsequent requests.

> Without env vars, it falls back to a default `you@example.com` email and a randomly generated password - and only runs in the `development` environment.

## Starting the server

```bash
bin/rails server
```

Runs on `http://localhost:3000` by default.

## API endpoints

Every endpoint (except `/api/v1/login`) requires an `Authorization: Bearer <token>` header.

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/login` | Log in with email + password → returns `api_token` |
| GET | `/api/v1/me` | Current user's details |
| GET | `/api/v1/feeds` | List the current user's feeds |
| POST | `/api/v1/feeds` | Add a new feed (`url`) |
| DELETE | `/api/v1/feeds/:id` | Delete a feed |
| GET | `/api/v1/items` | List items (paginated, filterable by `feed_id` / `unread`) |
| PATCH | `/api/v1/items/:id` | Mark an item as read/unread |

### Example: logging in

```bash
curl -X POST http://localhost:3000/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"session": {"email": "you@example.com", "password": "some-password"}}'
```

### Example: listing feeds

```bash
curl http://localhost:3000/api/v1/feeds \
  -H "Authorization: Bearer <api_token>"
```

## Background job: feed fetching

`FeedFetchJob` (Solid Queue) periodically polls registered feeds and creates new items. The schedule is defined in `config/recurring.yml`.

## Testing

```bash
bin/rspec
```

The feed-fetching specs use VCR cassettes and don't make live network calls.

## Status

Under active development - v1 goal: a single-user API built for personal use, serving the `cerrynt-cli` Go client. No public sign-up yet.

## License

TBD
