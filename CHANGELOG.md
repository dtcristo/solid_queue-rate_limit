# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `limits_rate to:, per:, burst: 1` for Active Job classes on Solid Queue. Workers admit a class's jobs at claim no faster than `to` per `per`, using GCRA, with up to `burst` at once from a recovered budget. A job over the limit waits as a scheduled job with a staggered next check, at most 5 minutes away, and keeps its own `scheduled_at`. `perform_now` and other adapters don't enforce it.
- `rate_limit_to`, `rate_limit_per`, `rate_limit_burst` and `rate_limited?` on job classes.
- `bin/rails generate solid_queue:rate_limit:install`, which copies the migration for `solid_queue_rate_limits` into the queue database. Enqueueing a limited job before it has run raises `SolidQueue::RateLimitState::PendingMigrations`, and workers hold back limited jobs.
- The `defer_rate_limited.solid_queue` event, with `class_name`, `job_ids` and `size`, logged at debug.
