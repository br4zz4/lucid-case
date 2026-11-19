require "test_helper"
require "action_controller"

class EventsReviewRegressionsTest < OutboxTest
  Registry = Lucid::Case::Events::Registry

  def delivery_job
    Lucid::Case::Events::DeliveryJob
  end

  def ordered_job
    Lucid::Case::Events::OrderedDeliveryJob
  end

  def enable_logging
    Lucid::Case.configuration.logging = :enabled
  end

  def build_post(name = "Ledger::Post")
    build_command(name) do
      logging :disabled
      attributes :entry
      define_method(:call!) { success(entry: entry) }
    end
  end

  def scheduled_in(job)
    value = job["scheduled_at"]
    time = value.is_a?(String) ? Time.iso8601(value) : Time.at(value)
    time - Time.now
  end

  def test_global_block_without_as_gets_a_stable_id_across_reloads
    # arrange
    target = approve_command
    declare = -> { Lucid::Case.subscribe(target) { |_event| nil } } ; line = __LINE__

    # act
    first = declare.call.subscriber_id
    Registry.clear!
    second = declare.call.subscriber_id

    # assert
    assert first.end_with?("events/review_regressions_test.rb:#{line}"), first
    assert_equal first, second
  end

  def test_global_block_without_as_is_delivered_by_the_job
    # arrange
    Lucid::Case.configuration.events.transport = :active_job
    target = approve_command
    received = []
    Lucid::Case.subscribe(target) { |event| received << event }

    # act
    perform_inline { target.call(enrollment: Order.create!(status: "pending")) }

    # assert
    assert_equal ["enrollment.approve"], received.map(&:name)
  end

  def test_job_does_not_raise_and_logs_when_subscription_left_the_registry
    # arrange
    enable_logging
    target = approve_command
    Lucid::Case.subscribe(target, as: :gone) { |_event| nil }
    target.call(enrollment: Order.create!(status: "pending"))
    row = record_class.order(:id).last
    Registry.clear!

    # act
    delivery_job.perform_now(row.uuid, "gone")

    # assert
    assert_match(/has no subscriber/, log.string)
    assert_includes log.string, "ERROR"
  end

  def test_job_is_silent_when_subscription_left_the_registry_and_logging_is_off
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :gone) { |_event| nil }
    target.call(enrollment: Order.create!(status: "pending"))
    row = record_class.order(:id).last
    Registry.clear!

    # act
    delivery_job.perform_now(row.uuid, "gone")

    # assert
    refute_match(/has no subscriber/, log.string)
  end

  def test_filter_parameters_hides_password_in_outbox_and_event
    # arrange
    hold_events
    Lucid::Case.configuration.filter_parameters = [:password]
    command = build_command("Account::Register") do
      logging :disabled
      attributes :params
      define_method(:call!) { success }
    end
    received = []
    Lucid::Case.subscribe(command, as: :listener) { |event| received << event }
    params = ActionController::Parameters.new(email: "a@x.com", password: "123").permit!

    # act
    command.call(params: params)
    row = record_class.order(:id).last
    delivery_job.perform_now(row.uuid, "listener")

    # assert
    refute_includes JSON.generate(row.payload), "123"
    assert_includes JSON.generate(row.payload), "a@x.com"
    assert_equal "[FILTERED]", received.sole.input.as_json["params"]["password"]
  end

  def destroying_command
    build_command("User::Remove") do
      logging :disabled
      transaction :enabled
      attributes :user
      define_method(:call!) do
        user.destroy
        success(user: user)
      end
    end
  end

  def test_destroying_record_in_inline_store_does_not_raise_and_delivers
    # arrange
    with_events(store: :inline)
    command = destroying_command
    spy(command)
    user = User.create!(name: "Ada")

    # act
    command.call(user: user)

    # assert
    assert_equal 0, User.where(id: user.id).count
    assert_equal ["user.remove"], events.map(&:name)
  end

  def test_destroying_record_in_outbox_store_does_not_raise_and_records
    # arrange
    hold_events
    command = destroying_command
    user = User.create!(name: "Ada")

    # act
    command.call(user: user)

    # assert
    assert_equal 0, User.where(id: user.id).count
    assert_equal ["user.remove"], record_class.all.map(&:name)
  end

  def test_delivery_job_drops_row_whose_record_was_destroyed
    # arrange
    enable_logging
    hold_events
    target = approve_command
    Lucid::Case.subscribe(target, as: :listener) { |_event| nil }
    order = Order.create!(status: "pending")
    target.call(enrollment: order)
    row = record_class.order(:id).last
    order.destroy
    clear_enqueued_jobs

    # act
    delivery_job.perform_now(row.uuid, "listener")

    # assert
    assert_empty enqueued_jobs
    assert_match(/dropped for/, log.string)
  end

  def test_event_to_h_serializes_records_as_global_ids
    # arrange
    user = User.create!(name: "Zelda-unique")
    event = Lucid::Case::Event.new(id: "e1", kind: :custom, name: "x", source: nil, occurred_at: Time.utc(2026, 1, 1),
                                   input: { user: user }, content: { user: user, list: [user] })

    # act
    json = JSON.generate(event.to_h)

    # assert
    refute_includes json, "Zelda-unique"
    assert_includes json, "gid://"
  end

  def test_event_round_trip_reloads_records
    # arrange
    user = User.create!(name: "Zelda-unique")
    event = Lucid::Case::Event.new(id: "e1", kind: :custom, name: "x", source: nil, occurred_at: Time.utc(2026, 1, 1),
                                   input: { user: user }, content: { user: user })

    # act
    rebuilt = Lucid::Case::Event.from_h(JSON.parse(JSON.generate(event.to_h)))

    # assert
    assert_equal user, rebuilt.content[:user]
    assert_equal user, rebuilt.input[:user]
    assert_equal "e1", rebuilt.id
  end

  def test_event_round_trip_keeps_plain_hashes
    # arrange
    event = Lucid::Case::Event.new(id: "e1", kind: :custom, name: "x", source: nil, occurred_at: Time.utc(2026, 1, 1),
                                   input: { a: 1 }, content: { b: [1, "two"] })

    # act
    rebuilt = Lucid::Case::Event.from_h(JSON.parse(JSON.generate(event.to_h)))

    # assert
    assert_equal({ a: 1 }, rebuilt.input)
    assert_equal({ b: [1, "two"] }, rebuilt.content)
  end

  def test_ordered_job_skips_unmatched_rows_without_deserializing_them
    # arrange
    hold_events
    target = build_post
    other = build_post("Other::Thing")
    received = []
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |event| received << event.content[:entry] }
    doomed = Order.create!(status: "x")
    other.call(entry: doomed)
    doomed.destroy
    post_target = ->(entry) { target.call(entry: entry) }
    post_target.call(1)
    100.times { |index| other.call(entry: index) }
    post_target.call(2)
    100.times { |index| other.call(entry: index) }
    post_target.call(3)

    # act
    ordered_job.perform_now("ledger")

    # assert
    assert_equal [1, 2, 3], received
  end

  def test_purge_with_ordered_subscriber_removes_unmatched_and_keeps_matched_above_cursor
    # arrange
    hold_events
    target = build_post
    other = build_post("Other::Thing")
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    other.call(entry: 1)
    target.call(entry: 2)
    unmatched = record_class.find_by(name: "other.thing")
    matched = record_class.find_by(name: "ledger.post")
    record_class.update_all(created_at: 30.days.ago, delivered_at: 30.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_nil record_class.find_by(id: unmatched.id)
    assert record_class.find_by(id: matched.id)
  end

  def test_delivery_job_failure_schedules_retry_with_backoff
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :broken) { |_event| raise "broken" }
    hold_events
    target.call(enrollment: Order.create!(status: "pending"))
    row = record_class.order(:id).last
    clear_enqueued_jobs

    # act
    delivery_job.perform_now(row.uuid, "broken")

    # assert
    retry_job = enqueued_jobs.last
    refute_nil retry_job["scheduled_at"]
    assert_operator scheduled_in(retry_job), :>=, 2
  end

  def test_ordered_job_failure_schedules_retry_with_backoff
    # arrange
    hold_events
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| raise "broken" }
    target.call(entry: 1)
    clear_enqueued_jobs

    # act
    ordered_job.perform_now("ledger")

    # assert
    retry_job = enqueued_jobs.last
    refute_nil retry_job["scheduled_at"]
    assert_operator scheduled_in(retry_job), :>=, 2
  end

  def test_transport_without_publish_is_rejected_by_configure
    # arrange
    # act
    error = assert_raises(ArgumentError) do
      Lucid::Case.configure { |config| config.events.transport = Object.new }
    end

    # assert
    assert_match(/transport/, error.message)
  end

  def test_invalid_delivery_attempts_are_rejected_by_configure
    # arrange
    # act
    # assert
    [0, "x"].each do |value|
      assert_raises(ArgumentError) { Lucid::Case.configure { |config| config.events.delivery_attempts = value } }
    end
  end

  def test_valid_transports_pass_configure
    # arrange
    # act
    # assert
    Lucid::Case.configure { |config| config.events.transport = :active_job }
    Lucid::Case.configure { |config| config.events.transport = CollectingTransport.new }
  end

  def test_relay_pending_purges_old_deduplication_rows_and_keeps_recent
    # arrange
    Lucid::Case.configuration.events.deduplication = :enabled
    Lucid::Case::Events::DeliveryRecord.create!(event_uuid: "old", subscriber: "s", created_at: 30.days.ago)
    Lucid::Case::Events::DeliveryRecord.create!(event_uuid: "new", subscriber: "s", created_at: 1.hour.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal ["new"], Lucid::Case::Events::DeliveryRecord.pluck(:event_uuid)
  end

  def test_relay_pending_leaves_deduplication_table_alone_when_disabled
    # arrange
    Lucid::Case::Events::DeliveryRecord.create!(event_uuid: "old", subscriber: "s", created_at: 30.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 1, delivery_count
  end
end
