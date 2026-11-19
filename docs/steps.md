# Steps

A case can be a list of named steps instead of a `call!`. Steps work in commands and queries.

```ruby
class Orders::Checkout < Lucid::Case::Command
  attributes :cart

  step(:validate_stock) do
    cart.items.all?(&:in_stock?) ? continue : failure(:out_of_stock)
  end

  step(:price) do
    continue(total: cart.items.sum(&:price))
  end

  step(:create_order) do
    success(order: Order.create!(cart: cart))
  end
end
```

A step block runs on the case instance, so attributes and private methods are available. It has to return one of four things:

- `continue(**content)` goes to the next step and adds `content`.
- `skip_to(:name, **content)` jumps ahead to the step `:name` and adds `content`.
- `success(**content)` ends the case with a success.
- `failure(type, **content)` ends it with a failure.

Returning anything else raises `UnexpectedResult`, and so does running out of steps without a `success` or `failure`. `skip_to` a step that does not exist, or one that is behind the current step, raises `ArgumentError`.

A case has `call!` or steps, not both. Declaring `step` in a class that defines `call!`, or defining `call!` in a class with steps, raises `AmbiguousDefinition` when the class loads.

## Accumulated content

The content from `continue` and `skip_to` piles up and is merged into the final result. If the same key shows up again, the content of the final `success` or `failure` wins.

```ruby
step(:a) { continue(x: 1) }
step(:b) { continue(y: 2) }
step(:c) { success(z: 3) }
```

The result has `{ x: 1, y: 2, z: 3 }`. A failure in `:b` would carry `x: 1`.

Turn this off for one case with `accumulate :disabled`, or for the app with `config.accumulate = :disabled`. Then the content given to `continue` and `skip_to` is dropped and only the final `success` or `failure` content is returned. Steps can still share state through instance variables.

```ruby
class Reports::Build < Lucid::Case::Query
  accumulate :disabled

  step(:load)  { @rows = Invoice.all.to_a; continue }
  step(:total) { success(total: @rows.sum(&:amount)) }
end
```

The case setting always wins over the global one, so `accumulate :enabled` turns it back on for a single case. Subclasses inherit the setting of their parent.

## A pipeline that saves its own failure

Provisioning is slow and talks to the network, so it should not hold a transaction. It also has to record that it failed, and that write must survive. The transaction is off, and `catch` does the saving:

```ruby
class Provisioning::Run < Lucid::Case::Command
  transaction :disabled

  attributes :provisioning

  step(:already_done) do
    provisioning.completed? ? success(provisioning: provisioning) : continue
  end

  step(:start) do
    provisioning.update!(status: :running, last_error: nil)
    continue
  end

  step(:dns) do
    result = Provisioning::Steps::Dns.call(provisioning: provisioning)
    result.success? ? continue(dns: result[:record]) : result
  end

  step(:finish) do
    provisioning.update!(status: :completed)
    success(provisioning: provisioning)
  end

  catch(StandardError) do |ctx|
    provisioning.update!(status: :failed, last_error: ctx.error.message)
    failure(:provisioning_failed, provisioning: provisioning, error: ctx.error)
  end
end
```

A step can return the result of another case, as `:dns` does on failure. Because nothing is wrapped in a transaction, the `failed` status is committed and the retry job sees it. See [Catch](catch.md).
