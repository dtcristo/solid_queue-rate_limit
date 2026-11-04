# Agent instructions

- Keep code in the style of upstream Solid Queue.
- Don't add too much complexity.
- Optimise the implementation for correctness, simple implementation and performance, all three of them, while still in the style of Solid Queue.
- When there are multiple ways to implement something, implement it the way Solid Queue does.
- Where something has a counterpart in Solid Queue or [solid_queue-coalesce](https://github.com/dtcristo/solid_queue-coalesce), make it work identically, such as how keys are built, column collations, and entry names in a job's serialized data. When the two differ, follow Solid Queue.
- APIs should look very Rails-like.
- Never alter Solid Queue's existing tables. Only add new ones.
- Add user-visible changes to the top section of `CHANGELOG.md` in the same PR. Only record what's on `main`, not what an open issue proposes.
- End each `CHANGELOG.md` entry with a full-URL link to its PR, such as `([#12](https://github.com/dtcristo/solid_queue-rate_limit/pull/12))`. Add it in a follow-up commit once the PR is open, and add another link when a later PR changes the entry.
- Start each version in `CHANGELOG.md` with a two or three sentence summary of what's new and whether upgrading takes work. Use full URLs, because the section gets copied unchanged into the GitHub release.
- Update the Compatibility section of the README when the gemspec or CI matrix changes.
- When a README recipe or the burst rule changes, update its test in the same PR. It's in `test/models/solid_queue/rate_limit_recipes_test.rb`. The tests define their own job classes, so they keep passing when they drift from the README.
- While you work, run only scoped tests locally, such as `TARGET_DB=sqlite bin/rails test test/unit/engine_test.rb`. CI runs the full suite and the matrix.
