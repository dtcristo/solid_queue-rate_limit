<div align="center">
  <h1>Solid Queue Rate Limit</h1>
  <p>
    <strong>Rate limits for <a href="https://github.com/rails/solid_queue">Solid Queue</a> jobs</strong>
  </p>
</div>

Solid Queue Rate Limit will add `limits_rate` to Active Job classes on Solid Queue. Nothing is released yet, and the gem has no behaviour so far. [#1](https://github.com/dtcristo/solid_queue-rate_limit/issues/1) describes what 0.1.0 will do.

## Table of contents

- [Getting started](#getting-started)
- [Compatibility](#compatibility)
- [License](#license)

## Getting started

Add the gem to your application's Gemfile, alongside Solid Queue:

```ruby
gem "solid_queue-rate_limit"
```

```bash
bundle install
```

The gem relies on private Solid Queue methods, so its gemspec allows one minor version of Solid Queue at a time.

[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Compatibility

| Dependency | Supported |
| --- | --- |
| Ruby | 3.2 and newer |
| Rails | 7.1, 7.2, 8.0 and 8.1. CI also runs Rails main, except on Ruby 3.2 |
| Solid Queue | 1.7 |
| Database | MySQL, PostgreSQL and SQLite |

CI runs Ruby 3.2, 3.3, 3.4 and 4.0 against all three databases.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
