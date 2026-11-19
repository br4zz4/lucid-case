# Queries

A query reads or computes. It never opens a transaction and cannot declare hooks or `transaction`.

```ruby
class Reports::Revenue < Lucid::Case::Query
  attributes :period

  def call!
    success(total: Invoice.where(period: period).sum(:amount))
  end
end
```

`Lucid::Case` with `kind :query` is the same thing:

```ruby
class Reports::Revenue < Lucid::Case
  kind :query
  cache duration: 10.minutes
  ...
end
```

`cache` needs the kind declared first, either with `kind :query` or by inheriting from `Query`. On a command it raises `CacheOnCommand`.

## Read-only

The body runs inside `ActiveRecord::Base.while_preventing_writes`, so any database write (insert, update, delete, DDL) raises `ActiveRecord::ReadOnlyError`. Declaring `transaction`, `after_success`, `after_failure` or `after_commit` raises `SideEffectInQuery` when the class loads.

Only the database is guarded. HTTP calls, emails, enqueued jobs (unless the queue is backed by the same database), file writes and `Rails.cache` writes go through unnoticed. Keeping them out of a query is up to you; if the case needs them, make it a command. A query that raises `ReadOnlyError` is a command.

## Caching

Queries can be cached by their inputs. See [Cache](cache.md).
