<div align="center">
  <h1>Solid Queue Rate Limit</h1>
  <p>
    <strong>Rate limits for <a href="https://github.com/rails/solid_queue">Solid Queue</a> jobs</strong>
  </p>
</div>

Solid Queue Rate Limit adds `limits_rate` to Active Job classes. Workers claim no more of a class's jobs in any period than you declare, and a job over the limit waits as a scheduled job instead of holding a worker thread, sleeping in `perform` or retrying after a 429.

```ruby
class SyncStripeJob < ApplicationJob
  limits_rate to: 100, per: 1.minute, burst: 10, key: :global

  def perform(account_id)
    Account.find(account_id).sync_to_stripe!
  end
end
```

The limit is checked when a worker claims the job, inside Solid Queue's own claim transaction, so it holds across any number of workers and processes on SQLite, PostgreSQL and MySQL. Unlimited jobs in the same queue keep running while limited ones wait.

To collapse repeated calls into one job before the limit sees them, pair it with [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce). The [last two recipes](#collapse-calls-for-each-account-and-run-them-one-at-a-time-under-a-global-rate) use both.

## Table of contents

- [Getting started](#getting-started)
- [Recipes](#recipes)
- [How waiting works](#how-waiting-works)
- [What the limit guarantees](#what-the-limit-guarantees)
- [Picking a burst for a backlog](#picking-a-burst-for-a-backlog)
- [Things to know](#things-to-know)
- [Clearing idle budgets](#clearing-idle-budgets)
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

The gem relies on private Solid Queue methods, so its gemspec allows one minor version of Solid Queue at a time, from 1.7.2.

To upgrade from an earlier version, follow [UPGRADING.md](UPGRADING.md). [CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Recipes

Start from what the API on the other end allows.

- [A quota per minute](#stay-under-a-quota-per-minute)
- [A fixed gap between calls](#space-jobs-out-evenly)
- [A high rate, with a backlog that has to keep up](#drain-a-backlog-at-the-full-rate)
- [A quota for each account](#give-each-account-a-budget)
- [One quota for several job classes](#share-a-budget-between-classes)
- [A quota for each account, used by several job classes](#share-a-budget-for-each-account-between-classes)
- [One job at a time for each account, under one quota](#run-one-job-at-a-time-for-each-account-under-a-global-rate)
- [One pending and one running job for each account, under one quota](#collapse-calls-for-each-account-and-run-them-one-at-a-time-under-a-global-rate)
- [A bulk API, with calls batched while they wait](#batch-calls-under-a-quota)

`Account`, `Address`, `Shop`, `Webhook` and the other names in these recipes stand in for your own code.

### Stay under a quota per minute

Use this when an API allows a number of calls in any minute and you want to stay under it with a burst for spikes.

```ruby
class SyncStripeCustomerJob < ApplicationJob
  # At most 100 claims in any minute, 10 of them at once
  limits_rate to: 100, per: 1.minute, burst: 10, key: :global

  def perform(account_id)
    Account.find(account_id).sync_to_stripe!
  end
end
```

A quiet budget lets 10 jobs through at once, then one every 60 / 91 seconds, about 0.66. That spacing leaves room for the burst, so no minute holds more than 100, and a backlog drains at 91 a minute. See [What the limit guarantees](#what-the-limit-guarantees).

### Space jobs out evenly

Use this when an API wants a gap between calls, and two calls close together would fail.

```ruby
class GeocodeAddressJob < ApplicationJob
  # The default burst: 1 never claims two jobs less than 5 seconds apart
  limits_rate to: 1, per: 5.seconds, key: :global

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
  # At most 10 in any second, draining a backlog at 10 - 6 + 1 = 5 a second.
  # 5 × (1 + 0.1) / 1 = 5.5, rounded up, for the default 1-second dispatcher poll and 0.1-second worker poll
  limits_rate to: 10, per: 1.second, burst: 6, key: :global

  def perform(webhook_id)
    Webhook.find(webhook_id).deliver!
  end
end
```

If 6 jobs at once is too many for the API, make the dispatcher poll more often instead. With a 0.2-second poll, `limits_rate to: 10, per: 1.second, burst: 3, key: :global` is enough, and leaves more of the 10 for the backlog, which drains at `10 - 3 + 1 = 8` a second. `8 × (0.2 + 0.1) / 1 = 2.4`, which rounds up to 3:

```yaml
# config/queue.yml
production:
  dispatchers:
    - polling_interval: 0.2
      batch_size: 500
```

A shorter poll means more queries from the dispatcher. Solid Queue's [configuration docs](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#configuration) cover `polling_interval` and `batch_size`.

### Give each account a budget

Use this when an API's quota is per account, per API key or per tenant, and one busy account shouldn't use up the others' share.

```ruby
class SyncShopOrdersJob < ApplicationJob
  # At most 2 calls in any second for each shop
  limits_rate to: 2, per: 1.second, burst: 2, key: ->(shop) { shop }

  def perform(shop)
    shop.sync_orders!
  end
end
```

`key:` gets the job's arguments, as in `limits_concurrency`. A record becomes its class name and id, so the shop with id 42 gets a budget of its own, stored under `SyncShopOrdersJob/Shop/42`. A Proc that returns `nil` sends the job to the class's bare budget, `SyncShopOrdersJob`. `burst: 2` follows the [backlog rule](#picking-a-burst-for-a-backlog), and applies to each shop, whose backlog drains at 1 a second.

### Share a budget between classes

Use this when several job classes call one API, and together they have to stay under its quota.

```ruby
class SyncStripeCustomerJob < ApplicationJob
  limits_rate to: 100, per: 1.minute, burst: 10, group: "Stripe", key: :global

  def perform(account_id)
    Account.find(account_id).sync_to_stripe!
  end
end

class RefundStripeChargeJob < ApplicationJob
  limits_rate to: 100, per: 1.minute, burst: 10, group: "Stripe", key: :global

  def perform(charge_id)
    Charge.find(charge_id).refund!
  end
end
```

Both classes draw on one budget, stored under `Stripe/global`. Declare the same limit in every class of a group, because each job is charged with its own class's settings. See [Rules and limitations](#rules-and-limitations).

### Share a budget for each account between classes

Use this when several job classes call an API whose quota is per account.

```ruby
class SyncStripeConnectAccountJob < ApplicationJob
  # At most 20 calls in any second for each account, with a 0.2-second dispatcher poll
  limits_rate to: 20, per: 1.second, burst: 5, group: "StripeConnect", key: ->(account) { account }

  def perform(account)
    account.sync_to_stripe!
  end
end

class CreateStripeTransferJob < ApplicationJob
  limits_rate to: 20, per: 1.second, burst: 5, group: "StripeConnect", key: ->(account, _amount) { account }

  def perform(account, amount)
    account.transfer!(amount)
  end
end
```

The account with id 7 gets one budget for both classes, stored under `StripeConnect/Account/7`. Each class's Proc gets its own job's arguments, so they can take different ones, as long as they return the same key for the same account. With the [0.2-second dispatcher poll](#drain-a-backlog-at-the-full-rate), `burst: 5` follows the [backlog rule](#picking-a-burst-for-a-backlog), and each account's backlog drains at 16 a second.

### Run one job at a time for each account, under a global rate

Use this when two syncs for one account mustn't run at once, and all accounts together have to stay under an API's quota.

```ruby
class SyncStripeAccountJob < ApplicationJob
  # One sync at a time for each account, and at most 100 claims in any minute across all of them
  limits_concurrency key: ->(account) { account }
  limits_rate to: 100, per: 1.minute, burst: 10, group: "Stripe", key: :global

  def perform(account)
    account.sync_to_stripe!
  end
end
```

Solid Queue gives each account one concurrency slot, and the gem checks the rate when a worker claims the job. A job over the rate gives its concurrency slot back while it waits, so the account's next blocked job can take it, and takes one again when it comes back. If there's none free by then, the job is blocked, as any job would be. `limits_concurrency` with `on_conflict: :discard` can't be combined with `limits_rate`, because a job that came back to a taken concurrency slot would be discarded.

### Collapse calls for each account and run them one at a time, under a global rate

Use this when an account's sync can be asked for many times, only the latest needs to run, two syncs for one account mustn't overlap, and all accounts together have to stay under an API's quota. It needs [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce).

```ruby
class SyncShopProductsJob < ApplicationJob
  # One pending and one running sync for each shop, and at most 2 claims in any second across them
  coalesce key: ->(shop) { shop }
  limits_concurrency key: ->(shop) { shop }
  limits_rate to: 2, per: 1.second, burst: 2, group: "Shopify", key: :global

  def perform(shop)
    shop.sync_products!
  end
end
```

Each control acts at a different step of the job's life:

| Step | What happens | Control |
| --- | --- | --- |
| `perform_later` | The call joins the shop's pending job, or creates one. The job stores the concurrency and rate limit keys of the call that created it | `coalesce` |
| The job becomes ready | It takes the shop's concurrency slot, or is blocked until the running sync finishes | `limits_concurrency` |
| A worker claims it | The budget admits it, or it waits as a scheduled job and gives its concurrency slot back | `limits_rate` |
| `perform` starts | The coalesce key is free, so the next call creates the next pending job | `coalesce` |
| `perform` finishes | The concurrency slot is free, and the shop's blocked job becomes ready | `limits_concurrency` |

A job waiting on the rate still holds its coalesce key, so calls keep joining it. With `debounce:`, a call can move it later than its rate check, but never earlier. With `on_full: :dispatch`, a full job that's waiting becomes ready, and the next claim sends it back to wait.

### Batch calls under a quota

Use this when an API has a bulk endpoint with a quota on requests, and calls arrive one item at a time. It needs [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce).

```ruby
class PushInventoryJob < ApplicationJob
  # Up to 100 SKUs in each request, and at most 10 requests in any minute for each shop
  coalesce key: ->(shop, _sku) { shop }, on_conflict: :collect, max_calls: 100
  limits_rate to: 10, per: 1.minute, burst: 2, key: ->(shop, _sku) { shop }

  def perform_calls(calls)
    shop = calls.first.arguments.first
    shop.push_inventory(calls.map { |call| call.arguments.last }.uniq)
  end
end
```

Each call joins the shop's pending job until it holds 100, and the limit is checked when a worker claims that job. A job waiting on the rate hasn't started, so calls keep joining it, and batches grow as the budget runs out. The limit counts claims, so make one bulk request in each run. A retry runs all of the job's calls again, and is charged again.

## How waiting works

When a worker claims jobs, the gem checks each limited job against its budget, in queue order, inside Solid Queue's claim transaction. A job the budget admits is claimed and runs like any other. A job over the limit moves from `solid_queue_ready_executions` to `solid_queue_scheduled_executions`, with a time to check again. It doesn't take a worker thread, and Active Job doesn't see a retry. When that time comes, the dispatcher makes it ready as usual, and the next claim checks it again.

The checks are staggered. Each waiting job gets the next free slot, one interval `per / (to - burst + 1)` after the last slot handed out, so 100 waiting jobs come back at 100 different times instead of all on the next poll. Each budget hands out its own slots, so a backlog on one account's key doesn't push back another account's jobs. Slots stop 5 minutes ahead. A job past that checks again in 5 minutes without taking a slot. If waiting jobs get discarded, or you loosen the limit, the slots they held come free within 5 minutes.

A slot is a hint, and never charges the budget. A job that comes back and finds the budget spent waits again, with the next free slot.

The job's own `scheduled_at` in `solid_queue_jobs` stays as it was enqueued. Only the scheduled execution carries the next check. `SolidQueue::Job#scheduled?` is true for a waiting job, so dashboards that read scheduled executions list it as scheduled.

Unlimited jobs keep running. Only limited jobs move to scheduled executions, and the rest of the batch is claimed as usual. When a claim deferred jobs and still has free threads, the worker claims again straight away, up to 5 times per poll, so its threads don't sit idle behind waiting jobs.

## What the limit guarantees

The limit counts claims at the worker gate, the moment a worker takes a job from `solid_queue_ready_executions`. It doesn't count job starts, finishes or the API calls a job makes.

Workers claim at most `to` of the jobs that share a budget in any window of `per`, starting at any moment. A quiet budget admits up to `burst` of them at once, and then one every `T = per / (to - burst + 1)`, which is how fast a backlog drains. With `burst: 1` that's even spacing, at least `per / to` apart. `limits_rate to: 100, per: 1.minute, burst: 10, key: :global` allows 10 claims at once, and 100 in any minute.

The limit isn't a rolling-window counter. It spaces claims so that a burst at the start of a window and the claims after it add up to `to`. So a larger burst leaves less of `to` for the rest of the window: `to: 100, burst: 100` admits 100 at once, then one a minute.

Some things fall outside it:

- A claim is charged when it happens, whatever happens next. A worker that crashes after claiming a job has used that budget.
- A job that comes back to ready is charged again. That covers a `retry_on` retry, a failed job you retry, and a claim released when a worker shuts down.
- A job can start a moment after its claim, make several API calls, or make one late in a long `perform`. Leave headroom if the API counts something else.
- A window that spans a change to the limit can hold more than either limit allows. See [`limits_rate` options](#limits_rate-options). So can a group whose classes declare different limits. See [Rules and limitations](#rules-and-limitations).
- Each worker reads the time from its own clock. Skew between hosts can let claims through closer together than `T`, so keep their clocks in sync, as Solid Queue's scheduled jobs already need.
- It's not FIFO. Jobs are checked in queue order within a claim, but a waiting job can be overtaken by one that arrives after the budget recovers, or one whose slot comes sooner.

## Picking a burst for a backlog

A job that reaches a worker while the budget has room runs straight away, whatever the burst. A backlog is different. Its jobs come back from waiting through the dispatcher, which promotes due jobs once per `polling_interval` (1 second by default), and a worker claims them shortly after.

`burst` also sets how early a job can reach the gate and still get in. Each burst above 1 allows one more interval `T`. With `burst: 1` there's no slack. A waiting job that arrives even a millisecond before the interval since the last claim has passed waits again, behind the rest of the backlog. Dispatch and claim delays vary by tens of milliseconds, so this happens to a good share of waiting jobs. Polling more often doesn't help, because the delays still vary.

A backlog drains at one job every `T`, that is `to - burst + 1` per `per`. To drain at that rate, `burst` has to cover two things. A dispatcher poll makes about `polling_interval / T` jobs due at once, and one claim takes them together. On top of that, the slack has to cover how much a worker's claim delay varies, which is up to the worker's own `polling_interval`. So set `burst` to at least `(dispatcher polling_interval + worker polling_interval) / T`, rounded up, and to at least 2.

For a limit of `to` per `per`, with `p` for the two polling intervals added up, that's `burst` of at least `(to + 1) × p / (per + p)`, rounded up, and at least 2. With Solid Queue's defaults of 1 and 0.1 seconds, that's `burst: 2` for `to: 2, per: 1.second`, which drains at 1 a second, and `burst: 6` for `to: 10`, which drains at 5. If the result is more than `to`, `per` is too short for the polls. Make the dispatcher poll more often, or accept a backlog that drains more slowly. The cost of a larger burst is that a quiet budget lets that many jobs through at once, and the backlog drains more slowly.

This is a rule of thumb that fits the measurements below and the recipe test's simulation, not a bound. Slow claims or busy workers can need more. In the simulation, a backlog draining at 100 jobs a second with a 0.1-second dispatcher poll fell behind with `to: 110, burst: 11` and kept up with `to: 119, burst: 20`.

These numbers come from 30 to 60 waiting jobs, with one worker polling every 0.1 seconds, on SQLite:

| Limit | `burst` | Dispatcher poll | Drains at, at most | Backlog drained at |
| --- | --- | --- | --- | --- |
| 1 per second | 1 | 1 s | 1 per second | 0.55 per second |
| 2 per second | 2 | 1 s | 1 per second | 0.95 per second |
| 1 per second | 1 | 0.1 s | 1 per second | 0.53 per second |
| 2 per second | 2 | 0.1 s | 1 per second | 1.0 per second |
| 3 per second | 2 | 1 s | 2 per second | 1.53 per second |
| 4 per second | 3 | 1 s | 2 per second | 1.9 per second |
| 9 per second | 5 | 1 s | 5 per second | 4.61 per second |
| 10 per second | 6 | 1 s | 5 per second | 4.91 per second |
| 1 per 3 seconds | 1 | 1 s | 1 per 3 seconds | 0.30 per second |
| 2 per 3 seconds | 2 | 1 s | 1 per 3 seconds | 0.33 per second |

## Things to know

- It's a separate gem that adds to Solid Queue from the outside, with its own table. It only works with the Solid Queue adapter, because it checks the limit inside Solid Queue's claim.
- It works with [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce), which coalesces calls when they're enqueued, before the limit checks the job at claim. See [Collapse calls for each account and run them one at a time, under a global rate](#collapse-calls-for-each-account-and-run-them-one-at-a-time-under-a-global-rate).
- The limit counts claims, not API calls. A larger `burst` leaves less of `to` for a backlog, which drains at `to - burst + 1` per `per`. See [What the limit guarantees](#what-the-limit-guarantees).
- With `burst: 1`, a backlog drains slower than `to` per `per`. See [Picking a burst for a backlog](#picking-a-burst-for-a-backlog).
- A waiting job is a scheduled job with its own `scheduled_at` kept, and checks again at most 5 minutes later. See [How waiting works](#how-waiting-works).
- Each job class has its own budgets, and so does each subclass, unless it declares `group:`. See [Rules and limitations](#rules-and-limitations).
- When the app is eager-loaded and no class declares `limits_rate`, claims run exactly Solid Queue's queries. Otherwise each claim reads the class names of the jobs it locked, reads the limited jobs' keys in one more query, and locks one row per budget. When it defers jobs that hold a concurrency slot, it loads them, gives their concurrency slots back and wakes the next blocked job for each.

## Clearing idle budgets

A budget gets a row in `solid_queue_rate_limits` the first time a claim needs it, and the row stays. With `key:`, that's a row for every account, shop or API key your jobs have used. `SolidQueue::RateLimitState.clear_idle_in_batches` deletes the rows of budgets that are full and have no slots handed out ahead. Such a row admits exactly as a missing one does, so clearing never changes what's admitted, and a claim that runs while it clears inserts the row again. Nothing runs it for you, so add it to your `recurring.yml`, as Solid Queue's installer does for finished jobs:

```yml
clear_solid_queue_rate_limits:
  command: "SolidQueue::RateLimitState.clear_idle_in_batches(sleep_between_batches: 0.3)"
  schedule: every hour at minute 27
```

It takes `batch_size:`, 500 by default, and `sleep_between_batches:`, like Solid Queue's `clear_finished_in_batches`.

## Compatibility

| Dependency | Supported |
| --- | --- |
| Ruby | 3.2 and newer |
| Rails | 7.1, 7.2, 8.0 and 8.1. CI also runs Rails main, except on Ruby 3.2 |
| Solid Queue | 1.7.2 and newer within 1.7 |
| Database | MySQL, PostgreSQL and SQLite |
| [Solid Queue Coalesce](https://github.com/dtcristo/solid_queue-coalesce) | Optional. CI tests 0.2 alongside |

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
limits_rate to:, per:, key:, burst: 1, group: ->(*) { self.class.name }
```

- `to` is required, and is a positive integer: the most jobs any `per` admits.
- `per` is required, and is a positive duration.
- `key` is required, and identifies the jobs that share a budget, as in `limits_concurrency`.
- `burst` is a positive integer, 1 by default, and at most `to`: how many jobs a quiet budget admits at once. After a burst, workers admit jobs `per / (to - burst + 1)` apart, which has to be at least 1 millisecond.
- `group` shares the budget with every class that names the same group. It takes the same values as `key`. Without it, the budget belongs to the class.

`key` and `group` work like the ones `limits_concurrency` takes, and the gem builds a budget's key the way Solid Queue builds a concurrency key: the group, or the class's name, then the key's value, joined with `/`.

```ruby
limits_rate to: 1, per: 1.second, key: :global                                       # Literal class-wide key: JobClass/global
limits_rate to: 1, per: 1.second, key: "global"                                      # Same literal component
limits_rate to: 1, per: 1.second, key: ->(account_id) { account_id }                 # Distinct per account
limits_rate to: 1, per: 1.second, key: ->(account) { account }                       # Active Record class and ID
limits_rate to: 1, per: 1.second, key: ->(account_id, kind) { [ account_id, kind ] } # Composite key
```

- A Symbol or String is a literal. `key: :account_id` doesn't read a parameter called `account_id`.
- A Proc receives the job's arguments.
- The result is joined into a string, so `1` and `"1"` give the same key.
- An array's items are joined with `/`, so `[ "a/b" ]` and `[ "a", "b" ]` give the same key.
- A Proc that returns `nil` gives the bare class-wide key, `JobClass`, or the group's, so all of those jobs share a budget.
- A declaration of `nil` or `false` disables the limit, as it disables `limits_concurrency`, so `key: nil` isn't a class-wide key. For one key per class, use a literal such as `:global`, or a Proc that returns `nil`. Other unsupported declaration types, such as `key: 123`, give the class-wide key.
- A key that comes out blank, such as with `group: nil` and a Proc that returns `nil`, leaves the job unlimited, as a blank concurrency key does.

Except for `key:`, an invalid option raises `ArgumentError` when the class loads. The class gets `rate_limit_to`, `rate_limit_per`, `rate_limit_burst`, `rate_limit_key`, `rate_limit_group` and `rate_limited?` to read them back.

The key is computed once, when Solid Queue enqueues the job, and stored with it, so a claim never deserializes arguments or loads records. A key Proc that raises fails the enqueue. `perform_now` and other adapters never run it.

Changing a limit and deploying applies to the next claim. A looser limit doesn't pay off all the debt the old one built up. The claim caps it at `burst` intervals of the new limit, rounded up to the microsecond, so new admissions start within one new interval and a microsecond. Jobs already waiting keep the next checks the old limit gave them, and new waiting jobs get slots after those, so a backlog can take up to 5 minutes to speed up. A tighter limit starts from the budget as the old one left it, so a window that spans the deploy can hold more than the new limit allows, until one new `per` has passed.

## Rules and limitations

- A class has one limit. A second `limits_rate` in the same class raises `ArgumentError`. `name:`, for multiple limits, raises `ArgumentError` until [#14](https://github.com/dtcristo/solid_queue-rate_limit/issues/14).
- A subclass inherits its parent's limit, `key:` and `group:`. Without a group, it has budgets of its own, so declaring `limits_rate` on `ApplicationJob` gives each job class its own budget, not one shared between them. A subclass can redeclare the limit, and then has only the `key:` and `group:` it declares. Redeclaring with `key: nil` turns the limit off.
- Every class in a group has to declare the same `to:`, `per:` and `burst:`. The gem doesn't check, as Solid Queue doesn't for concurrency groups. Each job is charged with its own class's settings against the shared budget, so with mixed settings a group can admit more than the stricter one allows.
- Keys aren't escaped, as concurrency keys aren't. A group named after a job class shares that class's budget, and `group: "Stripe", key: "a/b"` shares one with `group: "Stripe/a", key: "b"`. On MySQL, whose default collation ignores case, keys that differ only in case share one budget.
- A key longer than `solid_queue_rate_limits.key` allows, 255 characters on MySQL, raises `ActiveRecord::ValueTooLong` at enqueue, as an over-long concurrency key does. `perform_later` raises it wrapped in `SolidQueue::Job::EnqueueError`, and `perform_all_later` raises it as it is. PostgreSQL and SQLite have no limit.
- A retry keeps the key its job was enqueued with. That covers a `retry_on` retry, a failed job you retry, and a retry after the arguments failed to deserialize.
- A job keeps the key it was enqueued with while it waits, even if its class changes `key:` or `group:`. A job enqueued without a key, before its class declared a limit or by 0.1.0, uses the bare class-wide budget, `JobClass`, and gets the current key if it's retried.
- `limits_rate` combines with `limits_concurrency`, in either order and through inheritance. A job over the rate gives its concurrency slot back and wakes the next blocked job for its key once the claim commits, and takes one again when the dispatcher brings it back, or is blocked. `limits_concurrency` with `on_conflict: :discard` raises `ArgumentError` with `limits_rate`, because a job that came back to a taken concurrency slot would be discarded. A job that still has a concurrency key after its class dropped `limits_concurrency` is checked like any other.
- Without `group:`, the budget's key starts with the class's name. A job enqueued under an alias, such as a constant kept after a rename, keeps the key it was enqueued with, and shares the class's budget. On MySQL, two classes whose names differ only in case share one budget.
- A job whose class doesn't load, or whose `class_name` isn't a job class, is claimed without a check and fails as it would without the gem.
- A class that drops its limit has its waiting jobs claimed when they next check, at most 5 minutes later.

The design, and the costs behind these rules, are in [the design notes](https://github.com/dtcristo/solid_queue-rate_limit/blob/main/docs/design.md).

## Monitoring

| Event | When | Payload |
| --- | --- | --- |
| `defer_rate_limited.solid_queue` | A claim sent a class's jobs to wait | `class_name`, `keys`, `job_ids`, `size` |

A claim instruments one event for each class it deferred, inside its transaction. If the claim then rolls back, the event has still fired. `keys` lists the budgets that deferred them, once each. A job can wait more than once, so `size` counts deferrals, not distinct jobs. Jobs of a class that also declares `limits_concurrency` are included, and each blocked job one of them wakes instruments Solid Queue's own `release_blocked.solid_queue`.

`SolidQueue::LogSubscriber` logs it at debug level:

```text
SolidQueue-1.7.2 Defer rate-limited jobs (0.1ms)  class_name: "SyncStripeJob", keys: ["SyncStripeJob"], job_ids: [1, 2], size: 2
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

[#10](https://github.com/dtcristo/solid_queue-rate_limit/issues/10) tracks what's planned, including multiple limits per job and feedback from an API's 429 responses.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
