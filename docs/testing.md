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

## Events

In the test environment the generator sets `config.events.store = :inline`, so there is no table to clean and subscribers run right after the commit. To assert on the events themselves, include the helpers (they are not loaded by `require "lucid/case"`).

Minitest or ActiveSupport::TestCase:

```ruby
require "lucid/case/test_helpers"

class EnrollmentApproveTest < ActiveSupport::TestCase
  include Lucid::Case::TestHelpers

  test "emits the case event" do
    assert_event(Enrollment::Approve, type: :ok, content: { enrollment: enrollment }) do
      Enrollment::Approve.call(enrollment: enrollment)
    end
  end

  test "emits nothing on invalid input" do
    assert_no_event(Enrollment::Approve, type: :ok) { Enrollment::Approve.call(enrollment: nil) }
  end

  test "lists everything recorded" do
    events = capture_events { Payment::Charge.call(payment: payment) }
    assert_equal %w[credit_limit_reached payment.charge], events.map(&:name)
  end
end
```

RSpec:

```ruby
require "lucid/case/rspec"

RSpec.describe Enrollment::Approve do
  it "emits the case event" do
    expect { described_class.call(enrollment: enrollment) }
      .to emit_event(described_class).with(type: :ok, content: { enrollment: enrollment })
  end

  it "emits nothing on invalid input" do
    expect { described_class.call(enrollment: nil) }.not_to emit_event(described_class)
  end
end
```

Put the `require` in `rails_helper.rb` / `test_helper.rb`. `content:` and `input:` match as subsets. A custom event is matched by name (`emit_event(:credit_limit_reached)`) and a step event with `step:`.

Events are captured when they are recorded: nothing is written to the outbox, no subscriber runs, no job is enqueued and no table is needed. That works in a transactional test, and with `recording` off, as long as the command does not declare `events :disabled`. Events are captured when recorded, even if the transaction later rolls back, so `assert_no_event` around a command that emits and then fails still sees the emitted event; assert on the result for that. To test the reaction, call the subscriber directly with an event, or run the full path in a test that is not transactional (see Hooks above) with `store = :inline` or `perform_enqueued_jobs`.
