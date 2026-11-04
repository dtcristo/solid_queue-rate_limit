<div align="center">
  <h1>Solid Queue Rate Limit</h1>
  <p>
    <strong>Rate limits for <a href="https://github.com/rails/solid_queue">Solid Queue</a> jobs</strong>
  </p>
</div>

Solid Queue Rate Limit adds `limits_rate` to Active Job classes. Workers claim a class's jobs no faster than the rate you declare, and a job over the limit waits as a scheduled job instead of holding a worker thread, sleeping in `perform` or retrying after a 429.

```ruby
class SyncStripeJob < ApplicationJob
  limits_rate to: 100, per: 1.minute, burst: 10

  def perform(account_id)
    Account.find(account_id).sync_to_stripe!
  end
end
```

The limit is checked when a worker claims the job, inside Solid Queue's own claim transaction, so it holds across any number of workers and processes on SQLite, PostgreSQL and MySQL. Unlimited jobs in the same queue keep running while limited ones wait.

## Table of contents

- [Getting started](#getting-started)
- [Recipes](#recipes)
- [How waiting works](#how-waiting-works)
- [What the limit guarantees](#what-the-limit-guarantees)
- [Picking a burst for a backlog](#picking-a-burst-for-a-backlog)
- [Things to know](#things-to-know)
- [Compatibility](#compatibility)
- [`limits_rate` options](#limits_rate-options)
- [Rules and limitations](#rules-and-limitations)
- [Monitoring](#monitoring)
- [Testing](#testing)
- [Roadmap](#roadmap)
- [License](#license)

## Getting started

Add the gem to your application's Gemfile, alongside Solid Queue, then copy its migration to your queue database's migrations path and run it:

```ruby
gem "solid_queue-rate_limit"
```

```bash
bundle install
bin/rails generate solid_queue:rate_limit:install
bin/rails db:migrate
```

Add `limits_rate` to a job class, then pick a [recipe](#recipes) or read [Picking a burst for a backlog](#picking-a-burst-for-a-backlog).

### Where the migration goes

If Solid Queue doesn't use a database called `queue`, pass the right one with `--database`. For example, `bin/rails generate solid_queue:rate_limit:install --database primary`. Solid Queue's [database configuration](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#database-configuration) and [single database setup](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#single-database-configuration) cover the options.

The generator looks up that database in the current environment's `config/database.yml`. If it isn't there, the generator writes to `db/migrate` without warning, and the migration runs against your primary database. A new Rails app only defines `queue` under `production`, so generate the migration for that environment instead, and let `bin/rails db:prepare` run it when you deploy:

```bash
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails generate solid_queue:rate_limit:install
```

The migration should land in `db/queue_migrate`. `db/queue_schema.rb` doesn't pick up the new table from a production migration. That's fine, because `db:prepare` loads that schema into an empty database and then runs the migration.

### Before the migration runs

Until the migration has run, everything else works as before, and enqueuing a job that uses `limits_rate` raises `SolidQueue::RateLimitState::PendingMigrations`. A limited job that reaches a worker anyway, for example one enqueued before the class declared its limit, isn't claimed. It waits a minute at a time, and each worker process logs one error about the missing table. The limit fails closed, so it never lets jobs through unchecked.

Each process caches whether the table exists, so restart workers and web processes after you migrate. A deploy usually does that for you.

The gem relies on private Solid Queue methods, so its gemspec allows one minor version of Solid Queue at a time.

[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Recipes

Start from what the API on the other end allows.

- [A quota per minute](#stay-under-a-quota-per-minute)
- [A fixed gap between calls](#space-jobs-out-evenly)
- [A high rate, with a backlog that has to keep up](#drain-a-backlog-at-the-full-rate)

`Account`, `Address`, `Webhook` and the other names in these recipes stand in for your own code.

### Stay under a quota per minute

Use this when an API allows a number of calls in any minute and you want to stay under it with a burst for spikes.

```ruby
class SyncStripeCustomerJob < ApplicationJob
  # At most 10 + 90 = 100 claims in any minute
  limits_rate to: 90, per: 1.minute, burst: 10

  def perform(account_id)
    Account.find(account_id).sync_to_stripe!
  end
end
```

A quiet budget lets 10 jobs through at once, then one every 0.67 seconds. The limit isn't a rolling-window counter, so `to:` alone isn't the most a minute can hold. In any window of `w` seconds, workers claim at most `burst + floor(w / (per / to))` jobs. For a quota of `N` per `per`, keep `to + burst` at or below `N`. See [What the limit guarantees](#what-the-limit-guarantees).

### Space jobs out evenly

Use this when an API wants a gap between calls, and two calls close together would fail.

```ruby
class GeocodeAddressJob < ApplicationJob
  # The default burst: 1 never claims two jobs less than 5 seconds apart
  limits_rate to: 1, per: 5.seconds

  def perform(address_id)
    Address.find(address_id).geocode!
  end
end
```

With `burst: 1` there's no slack, so a backlog drains slower than one job every 5 seconds. [Picking a burst for a backlog](#picking-a-burst-for-a-backlog) explains why, and what it costs to fix.

### Drain a backlog at the full rate

Use this when a backlog builds up and has to drain at the declared rate.

```ruby
class SendWebhookJob < ApplicationJob
  # 5 × (1 + 0.1) / 1 = 5.5, rounded up, for the default 1-second dispatcher poll and 0.1-second worker poll
  limits_rate to: 5, per: 1.second, burst: 6

  def perform(webhook_id)
    Webhook.find(webhook_id).deliver!
  end
end
```

If 6 jobs at once is too many for the API, make the dispatcher poll more often instead. With a 0.2-second poll, `5 × (0.2 + 0.1) / 1 = 1.5`, which rounds up to 2, so `limits_rate to: 5, per: 1.second, burst: 2` is enough:

```yaml
# config/queue.yml
production:
  dispatchers:
    - polling_interval: 0.2
      batch_size: 500
```

A shorter poll means more queries from the dispatcher. Solid Queue's [configuration docs](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#configuration) cover `polling_interval` and `batch_size`.

## How waiting works

When a worker claims jobs, the gem checks each limited job against its class's budget, in queue order, inside Solid Queue's claim transaction. A job the budget admits is claimed and runs like any other. A job over the limit moves from `solid_queue_ready_executions` to `solid_queue_scheduled_executions`, with a time to check again. It doesn't take a worker thread, and Active Job doesn't see a retry. When that time comes, the dispatcher makes it ready as usual, and the next claim checks it again.

The checks are staggered. Each waiting job gets the next free slot, one interval `per / to` after the last slot handed out, so 100 waiting jobs come back at 100 different times instead of all on the next poll. Slots stop 5 minutes ahead. A job past that checks again in 5 minutes without taking a slot. If waiting jobs get discarded, or you loosen the limit, the slots they held come free within 5 minutes.

A slot is a hint, and never charges the budget. A job that comes back and finds the budget spent waits again, with the next free slot.

The job's own `scheduled_at` in `solid_queue_jobs` stays as it was enqueued. Only the scheduled execution carries the next check. `SolidQueue::Job#scheduled?` is true for a waiting job, so dashboards that read scheduled executions list it as scheduled.

Unlimited jobs keep running. Only limited jobs move to scheduled executions, and the rest of the batch is claimed as usual. When a claim deferred jobs and still has free threads, the worker claims again straight away, up to 5 times per poll, so its threads don't sit idle behind waiting jobs.

## What the limit guarantees

The limit counts claims at the worker gate, the moment a worker takes a job from `solid_queue_ready_executions`. It doesn't count job starts, finishes or the API calls a job makes.

With `T = per / to`, in any window of `w` seconds, workers claim at most `burst + floor(w / T)` of a class's jobs. With `burst: 1` that's even spacing, at least `T` apart. With a larger burst it isn't an exact rolling-window quota. `limits_rate to: 100, per: 1.minute, burst: 10` allows 110 claims in a minute that follows a quiet spell.

Some things fall outside it:

- A claim is charged when it happens, whatever happens next. A worker that crashes after claiming a job has used that budget.
- A job that comes back to ready is charged again. That covers a `retry_on` retry, a failed job you retry, and a claim released when a worker shuts down.
- A job can start a moment after its claim, make several API calls, or make one late in a long `perform`. Leave headroom if the API counts something else.
- Each worker reads the time from its own clock. Skew between hosts can let claims through closer together than `T`, so keep their clocks in sync, as Solid Queue's scheduled jobs already need.
- It's not FIFO. Jobs are checked in queue order within a claim, but a waiting job can be overtaken by one that arrives after the budget recovers, or one whose slot comes sooner.

## Picking a burst for a backlog

A job that reaches a worker while the budget has room runs straight away, whatever the burst. A backlog is different. Its jobs come back from waiting through the dispatcher, which promotes due jobs once per `polling_interval` (1 second by default), and a worker claims them shortly after.

`burst` also sets how early a job can reach the gate and still get in. Each burst above 1 allows one more interval `per / to`. With `burst: 1` there's no slack. A waiting job that arrives even a millisecond before the interval since the last claim has passed waits again, behind the rest of the backlog. Dispatch and claim delays vary by tens of milliseconds, so this happens to a good share of waiting jobs. Polling more often doesn't help, because the delays still vary.

For a backlog to drain at the full rate, `burst` has to cover two things. A dispatcher poll makes about `to × polling_interval / per` jobs due at once, and one claim takes them together. On top of that, the slack has to cover how much a worker's claim delay varies, which is up to the worker's own `polling_interval`. So set `burst` to at least `to × (dispatcher polling_interval + worker polling_interval) / per`, rounded up, and to at least 2. With Solid Queue's defaults of 1 and 0.1 seconds, that's `burst: 2` for 1 job a second, and `burst: 6` for 5. The cost is that a quiet budget lets that many jobs through at once.

This is a rule of thumb that fits the measurements below and the recipe test's simulation, not a bound. Slow claims or busy workers can need more. In the simulation, 100 jobs a second with a 0.1-second dispatcher poll fell behind with `burst: 11` and kept up with `burst: 20`.

These numbers come from 30 to 60 waiting jobs, with one worker polling every 0.1 seconds, on SQLite:

| Limit | Dispatcher poll | `burst` | Backlog drained at |
| --- | --- | --- | --- |
| 1 per second | 1 s | 1 | 0.55 per second |
| 1 per second | 1 s | 2 | 0.95 per second |
| 1 per second | 0.1 s | 1 | 0.53 per second |
| 1 per second | 0.1 s | 2 | 1.0 per second |
| 2 per second | 1 s | 2 | 1.53 per second |
| 2 per second | 1 s | 3 | 1.9 per second |
| 5 per second | 1 s | 5 | 4.61 per second |
| 5 per second | 1 s | 6 | 4.91 per second |
| 1 per 3 seconds | 1 s | 1 | 0.30 per second |
| 1 per 3 seconds | 1 s | 2 | 0.33 per second |

## Things to know

- It's a separate gem that adds to Solid Queue from the outside, with its own table. It only works with the Solid Queue adapter, because it checks the limit inside Solid Queue's claim.
- The limit counts claims, not API calls, and isn't an exact rolling-window quota once `burst` is above 1. See [What the limit guarantees](#what-the-limit-guarantees).
- With `burst: 1`, a backlog drains slower than the rate. See [Picking a burst for a backlog](#picking-a-burst-for-a-backlog).
- A waiting job is a scheduled job with its own `scheduled_at` kept, and checks again at most 5 minutes later. See [How waiting works](#how-waiting-works).
- Each job class has its own budget, and so does each subclass. See [Rules and limitations](#rules-and-limitations).
- When the app is eager-loaded and no class declares `limits_rate`, claims run exactly Solid Queue's queries. Otherwise each claim reads the class names of the jobs it locked, and locks one row per limited class.

## Compatibility

| Dependency | Supported |
| --- | --- |
| Ruby | 3.2 and newer |
| Rails | 7.1, 7.2, 8.0 and 8.1. CI also runs Rails main, except on Ruby 3.2 |
| Solid Queue | 1.7 |
| Database | MySQL, PostgreSQL and SQLite |

CI runs Ruby 3.2, 3.3, 3.4 and 4.0 against all three databases.

| Feature | Behaviour |
| --- | --- |
| `perform_later` and `perform_all_later` | Limited when a worker claims the job |
| `perform_now` | Runs straight away, unlimited |
| `set(wait:)` and `set(wait_until:)` | Dispatched at their time, then limited at claim. A job that waits keeps its `scheduled_at` |
| Recurring tasks | Limited like any other enqueue |
| Retries | Charged again when they come back to ready |
| Other adapters | Ignore `limits_rate`. See [Testing](#testing) |

## `limits_rate` options

```ruby
limits_rate to:, per:, burst: 1
```

- `to` is required, and is a positive integer: how many jobs a `per` admits.
- `per` is required, and is a positive duration. Workers admit jobs `per / to` apart, which has to be at least 1 millisecond.
- `burst` is a positive integer, 1 by default: how many jobs a quiet budget admits at once.

An invalid option raises `ArgumentError` when the class loads. The class gets `rate_limit_to`, `rate_limit_per`, `rate_limit_burst` and `rate_limited?` to read them back.

Changing a limit and deploying applies to the next claim. A looser limit doesn't pay off all the debt the old one built up. The claim caps it at `burst` intervals of the new limit, so new admissions start within one new interval. Jobs already waiting keep the next checks the old limit gave them, and new waiting jobs get slots after those, so a backlog can take up to 5 minutes to speed up. A tighter limit starts from the budget as the old one left it.

## Rules and limitations

- A class has one limit, and its budget belongs to that class. A second `limits_rate` in the same class raises `ArgumentError`.
- A subclass inherits its parent's limit, with a budget of its own. Declaring `limits_rate` on `ApplicationJob` gives each job class its own budget, not one shared between them. A subclass can redeclare the limit.
- `key:`, `group:` and `name:`, for keyed, shared and multiple limits, raise `ArgumentError` until [#3](https://github.com/dtcristo/solid_queue-rate_limit/issues/3).
- `limits_rate` and `limits_concurrency` on the same class raise `ArgumentError` in either order, and through inheritance, until [#2](https://github.com/dtcristo/solid_queue-rate_limit/issues/2). A job that still has a concurrency key, after its class switched from one to the other, is admitted without a rate check, because it holds its semaphore while it waits.
- The budget is stored under the class's name. A job enqueued under an alias, such as a constant kept after a rename, shares the class's budget. On MySQL, whose default collation ignores case, two classes whose names differ only in case share one budget.
- A job whose class doesn't load, or whose `class_name` isn't a job class, is claimed without a check and fails as it would without the gem.
- A class that drops its limit has its waiting jobs claimed when they next check, at most 5 minutes later.

The design, and the costs behind these rules, are in [the design notes](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/docs/design.md).

## Monitoring

| Event | When | Payload |
| --- | --- | --- |
| `defer_rate_limited.solid_queue` | A claim sent a class's jobs to wait | `class_name`, `job_ids`, `size` |

A claim instruments one event for each class it deferred, inside its transaction. If the claim then rolls back, the event has still fired. A job can wait more than once, so `size` counts deferrals, not distinct jobs.

`SolidQueue::LogSubscriber` logs it at debug level:

```text
SolidQueue-1.7.2 Defer rate-limited jobs (0.1ms)  class_name: "SyncStripeJob", job_ids: [1, 2], size: 2
```

A backlog can defer jobs on every claim, so the line isn't built at all above debug.

```ruby
ActiveSupport::Notifications.subscribe("defer_rate_limited.solid_queue") do |*, payload|
  Metrics.increment("solid_queue.rate_limit.deferred", payload[:size], tags: payload.slice(:class_name))
end
```

## Testing

`perform_now` and adapters other than Solid Queue's don't check the limit, and don't need the table. With the test adapter, `assert_enqueued_with` and `perform_enqueued_jobs` work as before, and jobs run as soon as you perform them.

Tests that run jobs through Solid Queue need the table in the test queue database, or enqueuing a limited job raises `SolidQueue::RateLimitState::PendingMigrations`.

## Roadmap

[#10](https://github.com/dtcristo/solid_queue-rate_limit/issues/10) tracks what comes after 0.1.0, including keyed and shared limits, combining with `limits_concurrency`, and feedback from an API's 429 responses.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
