# Testing

A case is a plain object. Call it and assert on the result.

```ruby
class UsersCreateTest < ActiveSupport::TestCase
  test "creates the user" do
    result = Users::Create.call(params: { name: "Ana" })

    assert result.success?
    assert_equal "Ana", result[:user].name
  end

  test "fails on invalid params" do
    result = Users::Create.call(params: { name: "" })

    assert result.failure?
    assert_equal :invalid, result.type
  end

  test "rejects a non-hash" do
    result = Users::Create.call(params: "nope")

    assert_equal :invalid_attributes, result.type
    assert_includes result[:errors].full_messages.join, "Params"
  end

  test "rolls back on failure" do
    assert_no_difference "User.count" do
      Orders::Cancel.call(order: shipped_order)
    end
  end
end
```

Pattern matching works in assertions too: `assert_pattern { result => { success: true, user: } }`. Plain Minitest works the same way, as long as ActiveRecord is connected for cases that touch the database.

## Hooks

`after_success` and `after_failure` run inside the case, so assert their effects directly.

`after_commit` waits for the outermost transaction, and Rails wraps each test in one, so its behavior in a transactional test depends on your Rails version and settings. To check that an `after_commit` effect fires only after a real commit, and never on failure, use a test that is not transactional:

```ruby
class UsersCreateCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown { User.delete_all }

  test "enqueues the job after commit" do
    assert_enqueued_with(job: WelcomeJob) do
      Users::Create.call(params: { name: "Ana" })
    end
  end

  test "enqueues nothing on failure" do
    assert_no_enqueued_jobs do
      Users::Create.call(params: { name: "" })
    end
  end

  test "drops the hook when the outer transaction rolls back" do
    assert_no_enqueued_jobs do
      ActiveRecord::Base.transaction do
        Users::Create.call(params: { name: "Ana" })
        raise ActiveRecord::Rollback
      end
    end
  end
end
```

## Cache

Caching needs `perform_caching` on and a real store. Rails turns `perform_caching` off in `test`, so queries run uncached and you need nothing unless you are testing the cache itself. In that case use a `MemoryStore`, set the config in `setup` and reset it in `teardown` so it does not leak into other tests:

```ruby
class RevenueCacheTest < ActiveSupport::TestCase
  setup do
    Lucid::Case.configure do |config|
      config.perform_caching = true
      config.cache_store = ActiveSupport::Cache::MemoryStore.new
      config.cache_scope = :global
    end
  end

  teardown { Lucid::Case.reset_configuration! }

  test "second call is a hit" do
    first = Reports::Revenue.call(period: period)
    second = Reports::Revenue.call(period: period)

    assert_nil first.cached_at
    assert second.cached?
  end

  test "stale forces a miss" do
    Reports::Revenue.call(period: period)

    assert Reports::Revenue.stale(period: period)
    assert_nil Reports::Revenue.call(period: period).cached_at
  end
end
```

## Instrumentation

```ruby
events = []
subscriber = ActiveSupport::Notifications.subscribe("call.lucid_case") { |*, payload| events << payload }
Users::Create.call(params: { name: "Ana" })
ActiveSupport::Notifications.unsubscribe(subscriber)

assert_equal :ok, events.first[:type]
```
