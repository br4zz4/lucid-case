# Catch and finally

`catch` turns an exception raised by a case into a result. It works the same with `call!` and with [steps](steps.md).

```ruby
class Orders::Charge < Lucid::Case::Command
  attributes :order

  catch(Gateway::Timeout) { |ctx| failure(:gateway_unavailable, error: ctx.error.message) }

  def call!
    Gateway.charge(order)
    success(order: order)
  end
end
```

A handler takes one or more exception classes and a block, and gets a context with `error` and `case`. The block runs on the case, so `failure` and your own methods are available. Calling `catch` without a class or without a block raises `ArgumentError`.

Handlers match with `is_a?` and only see `StandardError`s. Every handler that matches runs, in declaration order. If one returns a result, that is the outcome, and the last one to return a result wins. If none returns a result, the outcome is `failure(:exception, error: ctx.error)`. If no handler matches, the exception goes up.

```ruby
catch(Net::ReadTimeout, Faraday::Error) { |ctx| failure(:gateway_unavailable, error: ctx.error) }
catch(StandardError) { |ctx| Rails.logger.error(ctx.error) }
```

With both of these, a `Net::ReadTimeout` is logged by the second handler and still comes back as `:gateway_unavailable` from the first.

`catch` wraps the transaction. When an exception leaves a transactional case, the transaction rolls back first and the handler runs after, outside of it. If the case was called inside an outer transaction, that one is still open.

## finally

`finally` is cleanup that always runs when the case ends: after a success, after a failure, and after an exception, caught or not. It is the Java `finally`, and it pairs with `catch` the way it does there.

```ruby
class Imports::Run < Lucid::Case::Command
  attributes :import

  finally(:release_lock) { lock.release }

  catch(Timeout::Error) { |ctx| failure(:timeout, error: ctx.error.message) }

  def call!
    lock.acquire
    success(rows: import.run)
  end
end
```

The blocks run in the order they were declared, after the transaction has closed and after any `catch` handler, so the result is already decided and a `finally` cannot change it. The name is optional and only shows up in the log. If a `finally` block raises, that exception goes up. When the result comes from the cache, nothing runs, `finally` included. It works in commands and queries, with `call!` or steps.
