# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- CI tests [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce) 0.3 alongside, including `on_conflict: :replace`: a job waiting on the rate takes replacements and runs once with the latest arguments, keeps the rate limit key of the call that created it, and gives its concurrency slot back while it waits. ([#30](https://github.com/dtcristo/solid_queue-rate_limit/pull/30))

## [0.2.1] - 2026-11-06

Allows Solid Queue 1.7.0 and 1.7.1 again, and CI now tests every 1.7 release and Solid Queue main. Upgrading from 0.2.0 takes no work. On Solid Queue before 1.7.2, a job that combines `limits_rate` with `limits_concurrency` can let one extra job run for its key, as in Solid Queue itself, so upgrade Solid Queue to 1.7.2 to avoid that.

### Changed

- Allows Solid Queue 1.7.0 and 1.7.1 again, as 0.1.0 did. Combining `limits_rate` with `limits_concurrency` works on them as Solid Queue does: a deferred job whose semaphore expired can let one more job than the limit run, which Solid Queue 1.7.2 fixes. CI tests each 1.7 release and Solid Queue main, and runs each Ruby with one Rails instead of with every Rails. ([#28](https://github.com/dtcristo/solid_queue-rate_limit/pull/28))

## [0.2.0] - 2026-11-06

Adds a budget for each key with `key:` and `group:`, `limits_rate` and `limits_concurrency` on one class, a cleanup for idle budgets, and a retry for claims and dispatches that deadlock. Upgrading takes code changes but no migration: every `limits_rate` needs a `key:`, `to:` now includes the burst, and Solid Queue 1.7.2 is required. See [UPGRADING.md](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/UPGRADING.md).

### Added

- `key:` and `group:` for `limits_rate`, which take what `limits_concurrency` takes. `key:` gives each value a budget of its own, such as one for each account, and `group:` shares a budget between the classes that name it. The key is built like Solid Queue's concurrency key, worked out once when Solid Queue enqueues the job, and kept by its retries. Upgrading needs no migration. ([#19](https://github.com/dtcristo/solid_queue-rate_limit/pull/19), [#24](https://github.com/dtcristo/solid_queue-rate_limit/pull/24))
- `rate_limit_key` and `rate_limit_group` on job classes. ([#19](https://github.com/dtcristo/solid_queue-rate_limit/pull/19))
- `SolidQueue::RateLimitState.clear_idle_in_batches(batch_size: 500, sleep_between_batches: 0)`, which deletes the state rows of budgets that are full and have no slots ahead, so per-key rows don't pile up. Clearing never changes what's admitted, and a claim that runs while it clears inserts the row again. The README has a `recurring.yml` entry to run it every hour. ([#20](https://github.com/dtcristo/solid_queue-rate_limit/pull/20))
- `keys` in the `defer_rate_limited.solid_queue` payload and its log line, listing the budgets that deferred jobs. ([#19](https://github.com/dtcristo/solid_queue-rate_limit/pull/19))
- `limits_rate` and `limits_concurrency` on one class, in either order and through inheritance. A job over the rate waits as a scheduled job, and gives its concurrency slot back and wakes the next blocked job for its key once the claim commits. When the dispatcher brings it back, it takes a slot again or is blocked. `limits_concurrency(on_conflict: :discard)` with `limits_rate` still raises `ArgumentError`. The README has a recipe for one job at a time for each account under a global rate. ([#22](https://github.com/dtcristo/solid_queue-rate_limit/pull/22))
- README recipes that combine `limits_rate` with [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce) 0.2: collapsing calls for each account with `limits_concurrency` under a global rate, with a table of which control acts at each step, and batching calls for a bulk API under a quota. ([#23](https://github.com/dtcristo/solid_queue-rate_limit/pull/23))

### Changed

- **Breaking:** `limits_rate`'s `to:` is the most a budget admits in any `per`, burst included, as `to:` is in Rails' `rate_limit` and `limits_concurrency`. It was the steady rate, with the burst on top, so `to: 100, per: 1.minute, burst: 10` could admit 109 in a minute. After a burst, jobs are now spaced `per / (to - burst + 1)` apart, and a backlog drains at `to - burst + 1` per `per`. To keep a limit as 0.1.0 enforced it, add `burst - 1` to `to`. A `burst` above `to` raises `ArgumentError`, and the README's recipes and backlog rule use the new meaning. ([#25](https://github.com/dtcristo/solid_queue-rate_limit/pull/25))
- **Breaking:** `limits_rate` requires `key:`, as `limits_concurrency` and Solid Queue Coalesce's `coalesce` do, and `group:` defaults to Solid Queue's `->(*) { self.class.name }`. Add `key: :global` for one budget per class, stored as `JobClass/global`, or `key: ->(*) {}` to keep the 0.1.0 budget, stored as `JobClass`. A `nil` or `false` key turns the limit off, as it turns off `limits_concurrency`, and a job whose key comes out blank isn't limited, as a job whose concurrency key is blank isn't. With `:global`, jobs enqueued by 0.1.0 drain on the old budget while new ones use the new one, so the limit can admit up to twice its rate until they're gone. Every limited job stores its key, so each claim with limited jobs reads their keys in one more query. ([#24](https://github.com/dtcristo/solid_queue-rate_limit/pull/24))
- **Breaking:** Requires Solid Queue 1.7.2 or newer within 1.7, because giving a deferred job's concurrency slot back relies on 1.7.2 recording which semaphore a job holds. ([#22](https://github.com/dtcristo/solid_queue-rate_limit/pull/22))
- A job that still has a concurrency key after its class dropped `limits_concurrency` is checked against the rate, instead of being admitted without a check. ([#22](https://github.com/dtcristo/solid_queue-rate_limit/pull/22))
- `defer_rate_limited.solid_queue` includes jobs of classes that also declare `limits_concurrency`. Each blocked job a deferral wakes instruments Solid Queue's `release_blocked.solid_queue`. ([#22](https://github.com/dtcristo/solid_queue-rate_limit/pull/22))
- `name:` still raises `ArgumentError`, and now links to [#14](https://github.com/dtcristo/solid_queue-rate_limit/issues/14), which tracks multiple limits. ([#19](https://github.com/dtcristo/solid_queue-rate_limit/pull/19))
- Enqueueing a limited job before the migration has run raises `SolidQueue::RateLimitState::PendingMigrations` from every path into Solid Queue, including Solid Queue Coalesce's coalesced enqueues, which skipped the check when that gem's patch loaded after this one's. ([#23](https://github.com/dtcristo/solid_queue-rate_limit/pull/23))
- A claim whose first pass deadlocks, or a dispatcher batch that deadlocks, runs once more instead of raising, so a deadlock no longer stops the worker or the dispatcher. On MySQL, claims that insert a new budget's row at the same time can deadlock, which `key:` makes common, and so can a claim that defers jobs and a dispatcher batch. A second deadlock still raises. ([#19](https://github.com/dtcristo/solid_queue-rate_limit/pull/19), [#21](https://github.com/dtcristo/solid_queue-rate_limit/pull/21))

## [0.1.0] - 2026-11-04

The first release adds `limits_rate`, so workers claim a job class's jobs no faster than a declared rate, and jobs over it wait as scheduled jobs. Install it with `bin/rails generate solid_queue:rate_limit:install`, and there's nothing to upgrade from. The [README](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/README.md#what-the-limit-guarantees) states what the limit guarantees and how to pick a `burst` for a backlog.

### Added

- `limits_rate to:, per:, burst: 1` for Active Job classes on Solid Queue. Workers admit a class's jobs at claim no faster than `to` per `per`, using GCRA, with up to `burst` at once from a recovered budget. A job over the limit waits as a scheduled job with a staggered next check, at most 5 minutes away, and keeps its own `scheduled_at`. `perform_now` and other adapters don't enforce it. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- `rate_limit_to`, `rate_limit_per`, `rate_limit_burst` and `rate_limited?` on job classes. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- `bin/rails generate solid_queue:rate_limit:install`, which copies the migration for `solid_queue_rate_limits` into the queue database. Enqueueing a limited job before it has run raises `SolidQueue::RateLimitState::PendingMigrations`, and workers hold back limited jobs. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- The `defer_rate_limited.solid_queue` event, with `class_name`, `job_ids` and `size`, logged at debug. ([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))
- Requires Solid Queue 1.7. ([#11](https://github.com/dtcristo/solid_queue-rate_limit/pull/11))
- A README with recipes, the guarantee and a rule for picking `burst`, and [design notes](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/docs/design.md). ([#13](https://github.com/dtcristo/solid_queue-rate_limit/pull/13))

[Unreleased]: https://github.com/dtcristo/solid_queue-rate_limit/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/dtcristo/solid_queue-rate_limit/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/dtcristo/solid_queue-rate_limit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dtcristo/solid_queue-rate_limit/releases/tag/v0.1.0
