# Cerrynt Server

Rails backend and source of truth for Cerrynt, a multi-client RSS reader. Clients interact with it through a versioned JSON API.

## Status

Cerrynt Server is in early foundation development. The core data model, migrations, test suite, and CI pipeline are set up, but the API endpoints are not yet implemented. Development follows the task plan in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Tech Stack

The application currently uses:
- **Ruby:** 4.0.7 (pinned in `.ruby-version`)
- **Framework:** Rails 8.1 (API-only mode)
- **Database:** SQLite with Active Record
- **Web Server:** Puma
- **Authentication Support:** bcrypt (`has_secure_password`)
- **Solid Suite:** Solid Cache, Solid Queue, Solid Cable
- **Testing:** RSpec Rails, FactoryBot
- **Code Quality & Security:** RuboCop (`rubocop-rails-omakase`), Brakeman, bundler-audit

## Getting Started

### Prerequisites

- Ruby 4.0.7 (see `.ruby-version`)
- Bundler

### Setup

Clone the repository and run the setup script:

```bash
bin/setup --skip-server
```

This installs dependencies, prepares the SQLite database, and clears temporary files.

To seed a development user (requires `SEED_USER_PASSWORD` of at least 10 characters; an existing user keeps its password, and the password is never printed):

```bash
SEED_USER_PASSWORD=<at-least-10-chars> bin/rails db:seed
```

### Demo Account

The `demo:account` rake task creates or updates a demo user account (starting empty with plan `free`, no feeds, subscriptions, or entries). Both `DEMO_USER_EMAIL` and `DEMO_USER_PASSWORD` (10–72 bytes) are required; no defaults are used and the password is never printed.

```bash
DEMO_USER_EMAIL=demo@example.com DEMO_USER_PASSWORD=<at-least-10-chars> bin/rails demo:account
```

Re-running the task for an existing email rotates the password, keeps the user's current plan unchanged, and revokes all active API tokens for that user.

### Starting the Server

```bash
bin/rails server
```

The server boots on `http://localhost:3000` by default. A health check is available at `http://localhost:3000/up`.

Rate limiting relies on Rails caching. In development, caching can be enabled via `bin/rails dev:cache` (which creates `tmp/caching-dev.txt` and switches `config.cache_store` from `:null_store` to `:memory_store`). Ensure caching is enabled to test rate limiting locally.

Set `MAX_INTERACTIVE_FETCHES` to override the process-wide concurrency gate for synchronous feed subscriptions (defaults to `RAILS_MAX_THREADS - 1`, clamped to `1..(threads - 1)`).

## Running Tests and Checks

- **Run test suite:**
  ```bash
  bin/rails db:test:prepare && bundle exec rspec
  ```
- **Lint code:**
  ```bash
  bin/rubocop
  ```
- **Security scan:**
  ```bash
  bin/brakeman --no-pager
  bin/bundler-audit
  ```
- **Run full local CI pipeline:**
  ```bash
  bin/ci
  ```

## Documentation

- [`docs/ROADMAP.md`](docs/ROADMAP.md) — Implementation phases, target data model, scope, and progress.
- [`docs/API.md`](docs/API.md) — The API contract for clients.

## Related Projects

- [`cerrynt-cli`](https://github.com/mako/cerrynt-cli) — Terminal UI (TUI) client written in Go.

## License

TODO: license to be decided
