# Logging

Logging is off by default. Turn it on for the whole app in `config/initializers/lucid_case.rb`:

```ruby
Lucid::Case.configure do |config|
  config.logging = :enabled
end
```

Or for a single case. The case setting wins over the global one, and subclasses inherit it. `values: true` also logs the values:

```ruby
class Provisioning::Run < Lucid::Case
  kind :command
  logging :enabled, values: true
end

class Reports::Totals < Lucid::Case
  kind :query
  logging :disabled
end
```

## What you get

Each call logs its input, every step, any exception a step raised or a `catch` handled, and the result with how long it took:

```
[Lucid::Case] Provisioning::Run called input=[:provisioning, :token]
[Lucid::Case] Provisioning::Run step :start -> continue
[Lucid::Case] Provisioning::Run step :configure_dns raised Timeout::Error: dns down
[Lucid::Case] Provisioning::Run caught Timeout::Error: dns down -> failure(:timeout) content=[:error]
[Lucid::Case] Provisioning::Run failure(:timeout) content=[:error] in 0.5ms
```

Inside a case you can write your own lines with `logger`, which has `debug`, `info`, `warn` and `error`, takes a message or a block, and follows the case's `logging` setting:

```ruby
step(:charge) do
  logger.info("charging order ##{order.id}")
  continue
end
```

Exception messages can carry values (a unique violation names the duplicated value), so without values enabled only the exception class is logged: `raised Timeout::Error`.

A cached query adds `cache=hit`, `cache=miss` or `cache=bypass` (a `fresh` call) to the last line. An exception that no `catch` handles is logged as `raised ...` at `error` level and then propagates.

Lines about steps raising and exceptions being caught go out as `warn`. Everything else uses `config.log_level`, which is `:info` unless you change it. It sets the severity of the lines, it does not filter them: to log less, raise the level of your logger.

## Values stay out of the log

By default only names are logged: the input keys and the content keys, never what is inside them. That matters in apps that handle personal data.

`logging :enabled, values: true` in a case logs the values of that case as well, and `config.log_values = true` does it for every case. The values are passed through `ActiveSupport::ParameterFilter` with your app's `filter_parameters`, so a `token` or `password` shows as `[FILTERED]`. To use other filters, set `config.filter_parameters = [:token, /secret/]`. Check what your cases return before turning `log_values` on.

## Options

| Option | Default | |
|---|---|---|
| `logging` | `:disabled` | `:enabled` or `:disabled`. A case overrides it with `logging`. |
| `logger` | `Rails.logger` | Anything with `debug`, `info`, `warn` and `error`. Without a logger, nothing is logged. |
| `log_level` | `:info` | `:debug`, `:info`, `:warn` or `:error`. |
| `log_values` | `false` | Log filtered values, not only keys. |
| `filter_parameters` | the app's | Filters applied to logged values. |

Invalid values raise `ArgumentError`. Logging is separate from the `call.lucid_case` notification, which is always published.
