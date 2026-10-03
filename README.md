# Cerrynt API

Backend API for an RSS/Atom reader - manages feed subscriptions and read status via a JSON API. [`cerrynt-cli`](https://github.com/mako/cerrynt-cli) (a Go TUI client) consumes this API.

## Tech stack

- Ruby 3.4.10, Rails 8 (API-only mode)
- SQLite (Rails 8 default, [Litestream](https://litestream.io/)-compatible backups)
- [Solid Queue](https://github.com/rails/solid_queue) - background jobs (feed fetching), no separate Redis needed
- [Feedjira](https://github.com/feedjira/feedjira) - RSS/Atom parsing
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

The seed creates a user so you can test the endpoints.

```bash
SEED_USER_EMAIL="you@example.com" SEED_USER_PASSWORD="some-password" bin/rails db:seed
```

> Without env vars, it falls back to a default `you@example.com` email and a randomly generated password - and only runs in the `development` environment.

## Starting the server

```bash
bin/rails server
```

Runs on `http://localhost:3000` by default.

## Testing

```bash
bin/rspec
```

The feed-fetching specs use VCR cassettes and don't make live network calls.

## Status

Under active development - v1 goal: a single-user API built for personal use, serving the `cerrynt-cli` Go client. No public sign-up yet.

## License

TBD
