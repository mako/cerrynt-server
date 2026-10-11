# Cerrynt Server — Agent Guidelines

## Project
Cerrynt Server is the Rails backend and authoritative source of truth for Cerrynt, a multi-client RSS reader. Clients such as the Go TUI (`cerrynt-cli`) interact with it exclusively through the versioned JSON API. Refer to `docs/ROADMAP.md` for phases, data model, and development scope, and `docs/API.md` for the API contract (always update the contract before modifying endpoint behaviour).

## Working Agreement
- **Contract first:** If a task needs a change in `docs/API.md`, show the proposed change and wait for approval before touching code.
- **Honest reporting:** Never skip, delete or weaken tests or RuboCop rules to get green. If something fails, report it instead of working around it. Quote the actual summary line of every command you report.
- **Commit messages:** Suggest messages in Conventional Commits style (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `build:`, `style:`, `test:`).
- **Small steps:** Work on ONE roadmap task at a time. After each task, stop with a concise summary and clear verification instructions.
- **Git safety:** Never run `git commit`, `git push`, `git reset`, `git clean`, or `git checkout <file>`. The user reviews diffs and commits; only stage changes (`git add`).
- **File safety:** Ask before deleting any file, even newly created ones. Never place helper or scratch files in the repo (use `/tmp`).
- **Generators:** Do not run interactive generators with automatic confirmations (`yes y | ...`).
- **Dependencies:** Do not add a gem or dependency without asking first and providing a one-line rationale.
- **Ruby version:** Before starting a task, run `ruby -v` and confirm it matches `.ruby-version`; if it does not, stop and tell the user. Quote the Ruby version next to the results of the Definition of Done commands.
- **Scope & decisions:** Do not expand scope beyond `docs/ROADMAP.md`. If a decision is ambiguous, ask instead of guessing.
- **Roadmap tracking:** Tick the completed task in `docs/ROADMAP.md` only when the task passes all requirements.

## Definition of Done
Before reporting any task as done, verify and report the full results of:
1. `bin/rails zeitwerk:check` (must pass without autoloading errors).
2. Full `bin/rubocop` (must pass with zero offenses).
3. `bundle exec rspec` (must pass with all specs green).
Every behaviour change must be accompanied by specs (request specs for endpoints, model/service specs otherwise).

## Conventions
- **Language:** All code, comments, commit messages, and documentation must be in English.
- **Database:** SQLite for the MVP. Avoid SQLite-specific features so a future move to PostgreSQL remains seamless.
- **Architecture:** Idiomatic Rails 8. Thin controllers; extract plain Ruby service objects when domain logic grows.
- **Plans & Limits:** Plan limits must be handled exclusively through a central `Plan` object (no scattered magic numbers).
- **Authentication:** API tokens are opaque strings per device; only store the SHA-256 hex digest (`token_digest`).
- **Security:** Never log or commit secrets (use Rails credentials or environment variables).
- **Error Responses:** Match the standard JSON error shapes defined in `docs/API.md`.

## Verified Commands
- **Setup:** `bin/setup --skip-server` (or `bin/setup`)
- **Server:** `bin/rails server`
- **Seed database:** `bin/rails db:seed`
- **Run test suite:** `bin/rails db:test:prepare && bundle exec rspec` (or `bundle exec rspec`)
- **Lint code:** `bin/rubocop`
- **Security scan:** `bin/brakeman --no-pager && bin/bundler-audit`
- **Run local CI pipeline:** `bin/ci`
