# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `key:` and `group:` for `limits_rate`, which take what `limits_concurrency` takes. `key:` gives each value a budget of its own, such as one for each account, and `group:` shares a budget between the classes that name it. The key is built like Solid Queue's concurrency key, worked out once when Solid Queue enqueues the job, and kept by its retries. Classes without either keep their 0.1.0 budget, and upgrading needs no migration.
- `rate_limit_key` and `rate_limit_group` on job classes.
- `keys` in the `defer_rate_limited.solid_queue` payload and its log line, listing the budgets that deferred jobs.

### Changed

- `name:` still raises `ArgumentError`, and now links to [#14](https://github.com/dtcristo/solid_queue-rate_limit/issues/14), which tracks multiple limits.

## [0.1.0] - 2026-11-04

The first release adds `limits_rate`, so workers claim a job class's jobs no faster than a declared rate, and jobs over it wait as scheduled jobs. Install it with `bin/rails generate solid_queue:rate_limit:install`, and there's nothing to upgrade from. The [README](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/README.md#what-the-limit-guarantees) states what the limit guarantees and how to pick a `burst` for a backlog.

### Added

- `limits_rate to:, per:, burst: 1` for Active Job classes on Solid Queue. Workers admit a class's jobs at claim no faster than `to` per `per`, using GCRA, with up to `burst` at once from a recovered budget. A job over the limit waits as a scheduled job with a staggered next check, at most 5 minutes away, and keeps its own `scheduled_at`. `perform_now` and other adapters don't enforce it. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- `rate_limit_to`, `rate_limit_per`, `rate_limit_burst` and `rate_limited?` on job classes. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- `bin/rails generate solid_queue:rate_limit:install`, which copies the migration for `solid_queue_rate_limits` into the queue database. Enqueueing a limited job before it has run raises `SolidQueue::RateLimitState::PendingMigrations`, and workers hold back limited jobs. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- The `defer_rate_limited.solid_queue` event, with `class_name`, `job_ids` and `size`, logged at debug. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- Requires Solid Queue 1.7. ([#11](https://github.com/dtcristo/solid_queue-rate_limit/pull/11))
- A README with recipes, the guarantee and a rule for picking `burst`, and [design notes](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/docs/design.md). ([#13](https://github.com/dtcristo/solid_queue-rate_limit/pull/13))
