# Commands

A command changes state. `Lucid::Case` is a command unless you say otherwise, and `Lucid::Case::Command` just makes it explicit.

## Attributes

```ruby
class Invoices::Create < Lucid::Case::Command
  attributes :customer, :amount
  attributes :currency, default: "BRL"
  attributes :tags, default: -> { [] }
end

Invoices::Create.call(customer: customer, amount: 100)
```

Each attribute becomes a reader. Keys that were not declared are ignored, and a missing key is `nil` unless it has a `default:`. A default is either a value (duplicated on every call) or a callable. Subclasses inherit their parent's attributes without changing the parent. `attribute :a` declares one at a time.

## Validations

`validates` is ActiveModel. If the inputs are invalid, `call!` does not run and the result is `failure(:invalid_attributes, errors: errors)`.

```ruby
class Invoices::Create < Lucid::Case::Command
  attributes :customer, :amount
  validates :customer, presence: true, kind: Customer
  validates :amount, numericality: { greater_than: 0 }
end

result = Invoices::Create.call(customer: nil, amount: 0)
result.type                  # :invalid_attributes
result[:errors].full_messages
```

`kind:` checks `is_a?`. It takes a class, a list, or `with:`/`in:` plus an optional `message:`:

```ruby
validates :params, kind: Hash
validates :owner, kind: [User, Admin]
validates :id, kind: { with: Integer, message: "must be an integer" }
```

## success and failure

```ruby
success(invoice: invoice)
failure(:not_allowed, reason: "closed")
failure(reason: "boom")
```

`success` has type `:ok`. `failure` takes a type, `:error` by default. Anything else returned from `call!` raises `UnexpectedResult`. See [Result](result.md).

## kind

```ruby
class Orders::Cancel < Lucid::Case
  kind :command
  attributes :order
  ...
end
```

`kind :command` is the default, so writing it only documents intent. `kind :query` is what `Lucid::Case::Query` does for you. An unknown kind, or redeclaring a different kind (including in a subclass of `Command` or `Query`), raises `InvalidKind`. Declaring `kind :query` after a `transaction` or a hook raises `SideEffectInQuery`.

## Transaction

A command runs inside `ActiveRecord::Base.transaction(requires_new: true)`. Called from inside another transaction it becomes a savepoint, so a failure rolls back only this case. A `failure` rolls the transaction back. An exception rolls it back too and keeps going up, unless a [`catch`](catch.md) handles it.

```ruby
class Orders::Cancel < Lucid::Case::Command
  attributes :order

  def call!
    order.items.each(&:restock!)
    return failure(:already_shipped, order: order) if order.shipped?

    order.update!(status: :cancelled)
    success(order: order)
  end
end
```

When this returns `failure(:already_shipped)`, the `restock!` writes are undone.

Turn the transaction off for one case with `transaction :disabled`, or for the whole app with `config.transaction = :disabled`. The case setting wins. Do it when the case calls something outside the database (a slow HTTP call should not hold a transaction open), when it loops over independent items that must not undo each other, or when it has to save its own failure, as in the pipeline in [Steps](steps.md). With the transaction off nothing is rolled back for you, so wrap multi-write sections in your own `ActiveRecord::Base.transaction`.

## Hooks

```ruby
class Orders::Place < Lucid::Case::Command
  after_success :audit
  after_failure { |result| Rails.logger.warn("order failed: #{result.type}") }
  after_commit { |result| OrderMailer.with(order: result[:order]).confirmation.deliver_later }

  def call!
    ...
  end

  private

  def audit(result)
    AuditLog.create!(event: "order.placed", order_id: result[:order].id)
  end
end
```

A hook is a method name or a block. Either way it receives the result, and a block runs on the case instance.

After `call!` or the steps produce a result, the `after_success` hooks (on success) or `after_failure` hooks (on failure) run in declaration order, still inside the transaction. A hook that raises rolls the case back. Then the transaction commits or rolls back. `after_commit` hooks run last, only on success, once the outermost transaction has committed. If the case was called inside a transaction that later rolls back, they never run. With no transaction open they run right away.

Put jobs, mailers and events in `after_commit`: they never see uncommitted data and never fire for a rolled-back case.

Queries cannot declare hooks or `transaction`; doing so raises `SideEffectInQuery`.

A hook that raises is not special: `after_commit` runs after the case's own transaction commits but still inside the case, so a `catch` handler will see the exception and turn the result into a failure even though the data was already committed. Keep `after_commit` blocks to things that cannot fail, such as enqueueing a job.
