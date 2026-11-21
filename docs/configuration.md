# Configuration

```ruby
Lucid::Case.configure do |config|
  config.transaction = :enabled
  config.cache = :disabled
  config.cache_duration = 5.minutes
  config.accumulate = :enabled
  config.logging = :disabled
  config.cache_store = Rails.cache
  config.cache_scope = -> { Current.organization&.id }
  config.perform_caching = true
end
```

`bin/rails g lucid:case:install` writes this file with every option and its default, the ones you rarely touch commented out. Every case can override the global `transaction`, `cache`, `accumulate` and `logging` with a macro of the same name, and the case setting wins.

| Option | Default | |
|---|---|---|
| `transaction` | `:enabled` | `:enabled` or `:disabled`. Whether commands run in a transaction. |
| `cache` | `:disabled` | `:enabled` or `:disabled`. Whether queries are cached. |
| `cache_duration` | `5.minutes` | Default lifetime of an entry. A query overrides it with `cache duration:`. |
| `cache_store` | `Rails.cache` | Any `ActiveSupport::Cache::Store`. `nil` outside Rails. |
| `cache_scope` | none | Callable evaluated on each call, or `:global`. Required when caching is in use. |
| `perform_caching` | the app's `action_controller.perform_caching`; `true` outside Rails | Master switch. When false no query is cached. |
| `accumulate` | `:enabled` | `:enabled` or `:disabled`. Whether steps accumulate the content of `continue` and `skip_to`. See [Steps](steps.md). |
| `logging` | `:disabled` | `:enabled` or `:disabled`. See [Logging](logging.md). |
| `log_level` | `:info` | `:debug`, `:info`, `:warn` or `:error`. |
| `log_values` | `false` | Log filtered values instead of only keys. |
| `logger` | `Rails.logger` | Where the log lines go. |
| `filter_parameters` | the app's | Filters applied to logged values. |

`transaction`, `cache`, `accumulate`, `logging` and `log_level` raise `ArgumentError` on any other value. `configure` also raises it for `config.events` values that make no sense: a `transport` that is not `:active_job` and does not respond to `publish`, a `delivery_attempts` that is not a positive Integer, or deduplication with the `:inline` store.

`Lucid::Case.configuration` returns the current object, and `Lucid::Case.reset_configuration!` restores the defaults, which is useful in tests.

## Events

Options under `config.events`, written with every default by `bin/rails g lucid:case:events` (see [Events](events.md)).

| Option | Default | |
|---|---|---|
| `recording` | `:disabled` | `:enabled` or `:disabled`. Whether commands record events. A command overrides it with `events`. |
| `store` | `:outbox` | `:outbox` (table, at-least-once) or `:inline` (in-process, no table). |
| `transport` | `:active_job` | `:active_job`, or an object that responds to `publish(event)`. See [Event transports](event-transports.md). |
| `queue` | `:default` | Queue of the delivery jobs. |
| `delivery_attempts` | `5` | Executions of a delivery job before it gives up. |
| `table_name` | `"lucid_case_events"` | The outbox table. Accepts a qualified name such as `"public.lucid_case_events"`. |
| `deliveries_table_name` | `"lucid_case_deliveries"` | Deduplication table. |
| `cursors_table_name` | `"lucid_case_cursors"` | Cursors of ordered subscriptions. |
| `retention` | `7.days` | How long delivered rows are kept. |
| `purge` | `:enabled` | Whether `relay_pending` deletes delivered rows older than `retention`. |
| `claim_timeout` | `5.minutes` | How long a claimed row is held before another relay may take it. |
| `deduplication` | `:disabled` | Skip deliveries already made. Needs `:outbox`; `configure` raises `ArgumentError` with `:inline`. |
| `load_paths` | `%w[app/models]` | Directories loaded at boot and on reload so subscribers register. Must exist. |
| `context` | `nil` | Callable whose Hash is captured with each event. |
| `around_delivery` | `nil` | `->(context, &block)` that wraps each delivery. |
| `observers` | `[]` | Callables `->(event:, command:, result:)` run synchronously where each event is born. See [Events](events.md#observers). |

## Boot validation

The Railtie checks the configuration in `after_initialize`. `configure`, and a `cache` declaration made after boot, check it again, so classes that load lazily fail fast too.

The check only runs when `perform_caching` is true and caching is in use, meaning `config.cache = :enabled` or at least one query with `cache` enabled. An app that never caches, or runs with `perform_caching` off (usually development and test), never sees these errors even without a store or scope.

A `nil` or `NullStore` store raises `Error::CacheStoreMissing`, and a missing `cache_scope` raises `Error::MissingCacheScope`. See [Errors](errors.md).

## Instrumentation

Every call publishes `call.lucid_case` with `case:`, `kind:`, `type:` and `cache:`.

```ruby
ActiveSupport::Notifications.subscribe("call.lucid_case") do |event|
  Rails.logger.info("#{event.payload[:case]} #{event.payload[:type]} #{event.duration.round}ms cache=#{event.payload[:cache].inspect}")
end
```
