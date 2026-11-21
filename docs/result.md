# Result

Every call returns a frozen `Lucid::Case::Result`.

```ruby
result = Orders::Cancel.call(order: order)
result.success?
result.type
result[:order]
```

`type` is `:ok` for a success and the failure type otherwise (`:error` by default). `content`, `data` and `to_h` all return the content hash, and `[]` reads one key. The hash is a frozen shallow copy: you cannot mutate it, but the objects inside are the ones you passed. `case_class` is the class that produced the result. `cached?`, `cached_at` and `expires_at` describe a result served from the [cache](cache.md); on a fresh result `cached_at` and `expires_at` are `nil`.

## on_success and on_failure

Both return the result, so they chain. `on_failure` without a type matches any failure, with a type only that one.

```ruby
Orders::Cancel.call(order: order)
  .on_success { |result| redirect_to result[:order] }
  .on_failure(:already_shipped) { |result| flash[:alert] = "Already shipped" }
  .on_failure { |result| render :error, status: :unprocessable_entity }
```

Every matching block runs, so the untyped `on_failure` above also runs for `:already_shipped`. When the branches must be exclusive, use pattern matching.

## Pattern matching

The content keys are available, plus `type` and `success`.

```ruby
case Orders::Cancel.call(order: order)
in { success: true, order: }
  redirect_to order
in { success: false, type: :already_shipped }
  head :conflict
in { success: false, type: :invalid_attributes, errors: }
  render :new, locals: { errors: errors }
end
```

Invalid inputs give `failure(:invalid_attributes, errors: errors)`, where `errors` is an `ActiveModel::Errors`.

A [guard](guards.md) that holds gives `failure(type, errors: [message])`, where `errors` is an array with one String, plus any content added with `with:`.
