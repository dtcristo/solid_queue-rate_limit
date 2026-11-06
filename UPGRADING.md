# Upgrading from version 0.1.0 to 0.2.0

There's no migration. Update Solid Queue and every `limits_rate` declaration, then deploy.

1. Update Solid Queue to 1.7.2 or newer within 1.7. The gemspec requires it.
2. Add `key:` to every `limits_rate`. A declaration without it raises `ArgumentError` when its class loads.
3. If a declaration sets `burst` above 1, add `burst - 1` to `to` to keep the limit 0.1.0 enforced. `to:` is now the most a budget admits in any `per`, burst included. A declaration with the default `burst: 1` needs no change.

| 0.1.0 | 0.2.0, same limit and budget |
| --- | --- |
| `limits_rate to: 10, per: 1.minute` | `limits_rate to: 10, per: 1.minute, key: ->(*) {}` |
| `limits_rate to: 100, per: 1.minute, burst: 10` | `limits_rate to: 109, per: 1.minute, burst: 10, key: ->(*) {}` |

`key: ->(*) {}` keeps 0.1.0's budget, stored as the class name, so jobs enqueued by 0.1.0 share it with new ones. `key: :global` reads better, but it's a new budget, stored as `JobClass/global`. Jobs enqueued by 0.1.0 drain on the old budget while new ones use the new one, so the limit can admit up to twice its rate until they're gone. To avoid that, drain those jobs before you switch, or keep `key: ->(*) {}`.

A key for each value, such as `key: ->(account) { account }`, gives each value a budget of its own. Jobs enqueued by 0.1.0 have no key and drain on the old class-wide budget, which doesn't count against the new ones.

Deploy every worker together. A 0.1.0 worker checks every job against its class's old budget, whatever key the job stores, so while both versions run, a job with a new key can be admitted on both budgets.
