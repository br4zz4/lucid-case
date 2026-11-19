# Cache

Only queries can be cached, since a query is guaranteed read-only (see [Queries](queries.md)). Caching is opt-in per query, and it only happens when `perform_caching` is true and a real store is configured (see [Configuration](configuration.md)).

```ruby
class Dashboard::Evolution < Lucid::Case::Query
  cache duration: 5.minutes, version: 2

  attributes :period

  def call!
    success(points: Evolution.build(period))
  end
end
```

`cache :enabled` and `cache :disabled` override the global `config.cache`. `duration:` turns caching on if you gave no mode, and defaults to `config.cache_duration`. `version:` starts at 1 and is part of the key, so bump it on deploy to drop every entry of that case. `cache` on a command raises `CacheOnCommand`.

Only successful results are stored. On a hit nothing runs: no validation, no `call!`, no hooks. The stored result comes back as it is. It went through the store's serialization, so ActiveRecord objects inside it are a snapshot and are not reloaded. Cache plain data.

## Key

The key is made of the class name, the version, the scope, the scope's generation and a SHA-256 of the inputs. Inputs can be `nil`, booleans, symbols, strings, numbers, dates and times, hashes and arrays of those, `ActionController::Parameters`, and ActiveRecord records (through `cache_key_with_version`, so a changed record is a new key). Anything else raises `UncacheableInput`. Pass ids or records instead.

## Scope

`config.cache_scope` is required when caching is in use. It is a callable evaluated on every call, or `:global`.

```ruby
config.cache_scope = -> { Current.organization&.id }
config.cache_scope = -> { ActiveRecord::Base.connection.schema_search_path }
config.cache_scope = :global
```

In a multi-tenant app, scope by tenant. If two tenants can send the same inputs (a query with no attributes, an id that exists in both), a missing or wrong scope serves one tenant's data to the other. `:global` is only for data that is the same for everyone. If the callable returns `nil`, `MissingCacheScope` is raised instead of sharing.

## Store

`config.cache_store` defaults to `Rails.cache`, and entries live for the case's duration. A `NullStore`, or no store, is a boot error when caching is in use.

## fresh and stale

```ruby
Reports::Revenue.fresh.call(period: period)
Reports::Revenue.stale(period: period)
Reports::Revenue.stale(:period)
Reports::Revenue.stale
```

`fresh.call` ignores the cache, runs the query and stores the new result. `stale(period: period)` drops the entry for those inputs, so the next call runs the query again; it returns `true` if there was one. `stale(:period)` says something about `period` changed and drops every entry of the case in the current scope. The cache keeps no per-attribute index, so it can drop more than needed, never less. A name that is not an attribute raises `ArgumentError`, as does mixing names with inputs. `stale` with no arguments also drops every entry in the current scope: it bumps the scope's generation, so older keys become unreachable and age out of the store on their own. Other scopes are not touched.

A query with no attributes has one entry per scope, and `stale` with no arguments is how you invalidate it. All three methods exist only on queries; on a command they raise `NoMethodError`.

## cached_at and expires_at

```ruby
result = Reports::Revenue.call(period: period)
result.cached?
result.cached_at
result.expires_at
```

A result that was just computed has `cached_at: nil`. A hit carries the time the entry was written and when it expires, which is handy for the UI:

```erb
<% if result.cached? %>
  Updated <%= time_ago_in_words(result.cached_at) %> ago
  <%= button_to "Refresh", refreshes_path(period_id: period.id) %>
<% end %>
```

## Instrumentation

`call.lucid_case` events carry `cache:` with `:hit`, `:miss`, `:bypass` (from `fresh`) or `nil` when the query is not cached. The log line gets a `cache=` suffix too; see [Logging](logging.md).
