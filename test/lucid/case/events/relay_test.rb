require "test_helper"

class EventsRelayTest < OutboxTest
  def relay
    Lucid::Case::Events::Relay
  end

  def test_commit_relays_in_process_and_marks_delivered
    # arrange
    transport = collect_events
    command = approve_command
    order = Order.create!(status: "a")

    # act
    command.call(enrollment: order)

    # assert
    row = record_class.sole
    assert_equal [row.uuid], transport.published.map(&:id)
    refute_nil row.delivered_at
    assert_equal order, transport.published.first.content[:enrollment]
  end

  def test_publish_happens_only_after_the_outer_commit
    # arrange
    transport = collect_events
    command = approve_command
    order = Order.create!(status: "a")
    seen = nil

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      seen = transport.published.size
    end

    # assert
    assert_equal 0, seen
    assert_equal 1, transport.published.size
  end

  def test_outer_rollback_publishes_nothing
    # arrange
    transport = collect_events
    command = approve_command
    order = Order.create!(status: "a")

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      raise ActiveRecord::Rollback
    end

    # assert
    assert_empty transport.published
  end

  def test_active_job_transport_enqueues_one_job_per_subscriber
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :first) { |_event| nil }
    Lucid::Case.subscribe(target, as: :second) { |_event| nil }

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    row = record_class.sole
    assert_equal 2, delivery_arguments.size
    assert_equal [row.uuid], delivery_arguments.map(&:first).uniq
    assert_equal %w[first second], delivery_arguments.map { |args| args.last.to_s }.sort
    refute_nil row.delivered_at
  end

  def test_active_job_transport_enqueues_on_the_configured_queue
    # arrange
    Lucid::Case.configuration.events.queue = :events
    target = approve_command
    Lucid::Case.subscribe(target, as: :first) { |_event| nil }

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal ["events"], enqueued_jobs.map { |job| job["queue_name"] }
  end

  def test_subscriber_matching_twice_gets_a_single_job
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      subscribe target
      subscribe target, on: :any
      define_method(:call!) { success }
    end

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, delivery_arguments.size
  end

  def test_unmatched_subscription_is_not_enqueued
    # arrange
    target = approve_command
    other = build_command("Enrollment::Reject") { define_method(:call!) { success } }
    Lucid::Case.subscribe(other, as: :other) { |_event| nil }

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty delivery_arguments
  end

  def test_no_subscribers_enqueues_nothing_but_marks_delivered
    # arrange
    target = approve_command

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty enqueued_jobs
    refute_nil record_class.sole.delivered_at
  end

  def test_app_transport_receives_event_that_round_trips
    # arrange
    transport = collect_events
    command = approve_command
    order = Order.create!(status: "a")
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }

    # act
    command.call(enrollment: order)

    # assert
    event = transport.published.first
    assert_kind_of Lucid::Case::Event, event
    assert_equal event, Lucid::Case::Event.from_h(event.to_h)
  end

  def test_relay_claims_rows_and_publishes_each_once
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    transport = collect_events
    uuids = record_class.pluck(:uuid)

    # act
    relay.relay(uuids)
    relay.relay(uuids)

    # assert
    assert_equal uuids, transport.published.map(&:id)
    refute_nil record_class.sole.delivered_at
  end

  def test_transport_failure_does_not_reach_the_caller_and_row_stays_pending
    # arrange
    transport = hold_events
    command = approve_command

    # act
    result = command.call(enrollment: Order.create!(status: "a"))

    # assert
    row = record_class.sole
    assert result.success?
    assert_equal 1, transport.attempts
    assert_nil row.delivered_at
    assert_nil row.claimed_at
    assert_nil row.claim_token
  end

  def test_relay_pending_delivers_after_transport_failure
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!
    transport = collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    row = record_class.sole
    assert_equal [row.uuid], transport.published.map(&:id)
    refute_nil row.delivered_at
  end

  def test_relay_pending_ignores_rows_younger_than_a_minute
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    transport = collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_empty transport.published
    assert_nil record_class.sole.delivered_at
  end

  def test_relay_pending_skips_rows_with_an_active_claim
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!
    record_class.update_all(claimed_at: Time.current, claim_token: "other-process")
    transport = collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    row = record_class.sole
    assert_empty transport.published
    assert_nil row.delivered_at
    assert_equal "other-process", row.claim_token
  end

  def test_relay_pending_takes_over_an_expired_claim
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!
    record_class.update_all(claimed_at: 10.minutes.ago, claim_token: "dead-process")
    transport = collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 1, transport.published.size
    refute_nil record_class.sole.delivered_at
  end

  def test_relay_with_an_active_foreign_claim_publishes_nothing
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    record_class.update_all(claimed_at: Time.current, claim_token: "other-process")
    transport = collect_events

    # act
    relay.relay(record_class.pluck(:uuid))

    # assert
    assert_empty transport.published
  end

  def test_relay_pending_processes_in_batches_of_500
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    template = record_class.sole.attributes.except("id")
    rows = Array.new(600) { |index| template.merge("uuid" => SecureRandom.uuid, "name" => "bulk.#{index}") }
    record_class.insert_all!(rows)
    age_pending!
    transport = collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 601, transport.published.size
    assert_equal 0, record_class.where(delivered_at: nil).count
  end

  def test_relay_pending_raises_relay_failed_after_the_whole_batch
    # arrange
    transport = hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    approve_command.call(enrollment: Order.create!(status: "b"))
    age_pending!
    attempts_before = transport.attempts

    # act
    error = assert_raises(Lucid::Case::Error::RelayFailed) { Lucid::Case::Events.relay_pending }

    # assert
    uuids = record_class.pluck(:uuid)
    assert_equal 2, transport.attempts - attempts_before
    uuids.each { |uuid| assert_includes error.message, uuid }
    assert_equal 2, record_class.where(delivered_at: nil, claim_token: nil).count
  end

  def test_relay_pending_does_not_raise_when_everything_is_delivered
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!
    collect_events

    # act / assert
    Lucid::Case::Events.relay_pending
  end

  def test_relay_pending_purges_old_delivered_rows_but_never_pending
    # arrange
    collect_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    hold_events
    approve_command.call(enrollment: Order.create!(status: "b"))
    delivered = record_class.where.not(delivered_at: nil).sole
    pending = record_class.where(delivered_at: nil).sole
    delivered.update_columns(delivered_at: 8.days.ago)
    pending.update_columns(created_at: 30.days.ago)
    collect_events

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_nil record_class.find_by(id: delivered.id)
    refute_nil record_class.find_by(id: pending.id)
  end

  def test_purge_keeps_rows_delivered_within_retention
    # arrange
    collect_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    record_class.update_all(delivered_at: 6.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 1, record_class.count
  end

  def test_purge_disabled_deletes_nothing
    # arrange
    Lucid::Case.configuration.events.purge = :disabled
    collect_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    record_class.update_all(delivered_at: 30.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 1, record_class.count
  end

  def test_purge_runs_before_relay_failed_is_raised
    # arrange
    collect_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    record_class.update_all(delivered_at: 30.days.ago)
    hold_events
    approve_command.call(enrollment: Order.create!(status: "b"))
    age_pending!
    record_class.where.not(delivered_at: nil).update_all(delivered_at: 30.days.ago)

    # act
    assert_raises(Lucid::Case::Error::RelayFailed) { Lucid::Case::Events.relay_pending }

    # assert
    assert_equal 1, record_class.count
    assert_nil record_class.sole.delivered_at
  end

  def test_logs_relay_failure_with_publisher_logging_enabled
    # arrange
    hold_events
    command = approve_command(logging: :enabled)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    uuid = record_class.sole.uuid
    assert_match(/ERROR.*\[Lucid::Case\].*event "enrollment.approve" id=#{uuid} relay failed: IOError/, log.string)
  end

  def test_relay_failure_is_silent_with_logging_disabled
    # arrange
    hold_events
    command = approve_command(logging: :disabled)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty event_log_lines.reject { |line| line.include?("recorded id=") }
    refute_includes log.string, "relay failed"
  end

  def test_relay_pending_logs_failure_with_global_logging_enabled
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!
    Lucid::Case.configuration.logging = :enabled

    # act
    assert_raises(Lucid::Case::Error::RelayFailed) { Lucid::Case::Events.relay_pending }

    # assert
    uuid = record_class.sole.uuid
    assert_match(/ERROR.*event "enrollment.approve" id=#{uuid} relay failed: IOError/, log.string)
  end

  def test_relay_pending_is_silent_with_global_logging_disabled
    # arrange
    hold_events
    approve_command.call(enrollment: Order.create!(status: "a"))
    age_pending!

    # act
    assert_raises(Lucid::Case::Error::RelayFailed) { Lucid::Case::Events.relay_pending }

    # assert
    refute_includes log.string, "relay failed"
  end
end
