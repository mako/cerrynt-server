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

To seed a development user:

```bash
bin/rails db:seed
```

### Starting the Server

```bash
bin/rails server
```

The server boots on `http://localhost:3000` by default. A health check is available at `http://localhost:3000/up`.

Rate limiting relies on Rails caching. In development, caching can be enabled via `bin/rails dev:cache` (which creates `tmp/caching-dev.txt` and switches `config.cache_store` from `:null_store` to `:memory_store`). Ensure caching is enabled to test rate limiting locally.

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
