require "test_helper"

module OrderedLockSpy
  def lock!(*)
    log = Thread.current[:lucid_lock_log]
    log << self.class.connection.open_transactions if log
    super
  end
end

class EventsOrderedDeliveryTest < OutboxTest
  def job
    Lucid::Case::Events::OrderedDeliveryJob
  end

  def setup
    super
    hold_events
  end

  def build_post(name = "Ledger::Post")
    build_command(name) do
      logging :disabled
      attributes :entry
      define_method(:call!) { success(entry: entry) }
    end
  end

  def post(command, entry)
    command.call(entry: entry)
    record_class.order(:id).last
  end

  def subscriber_id(name)
    Lucid::Case::Events::Registry.subscriptions.find { |subscription| subscription.subscriber_id.to_s == name }.subscriber_id
  end

  def cursor_value(name)
    connection = ActiveRecord::Base.connection
    connection.select_value("SELECT last_event_id FROM #{cursors_table} WHERE subscriber = #{connection.quote(name)}")&.to_i
  end

  def cursor_rows
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{cursors_table}").to_i
  end

  def set_cursor(name, value)
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM #{cursors_table} WHERE subscriber = #{connection.quote(name)}")
    connection.execute("INSERT INTO #{cursors_table} (subscriber, last_event_id) VALUES (#{connection.quote(name)}, #{value.to_i})")
  end

  def ordered_arguments
    enqueued_jobs.select { |item| item["job_class"] == "Lucid::Case::Events::OrderedDeliveryJob" }
                 .map { |item| ActiveJob::Arguments.deserialize(item["arguments"]) }
  end

  def test_active_job_transport_enqueues_the_ordered_job_with_only_the_subscriber
    # arrange
    Lucid::Case.configuration.events.transport = :active_job
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }

    # act
    post(target, 1)

    # assert
    assert_equal [["ledger"]], ordered_arguments.map { |args| args.map(&:to_s) }
    assert_empty delivery_arguments
  end

  def test_unordered_subscribers_keep_the_delivery_job
    # arrange
    Lucid::Case.configuration.events.transport = :active_job
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    Lucid::Case.subscribe(target, as: :mailer) { |_event| nil }

    # act
    row = post(target, 1)

    # assert
    assert_equal [["ledger"]], ordered_arguments.map { |args| args.map(&:to_s) }
    assert_equal [[row.uuid, "mailer"]], delivery_arguments.map { |args| args.map(&:to_s) }
  end

  def test_block_subscription_without_as_raises_when_ordered
    # arrange
    target = build_post

    # act
    error = assert_raises(Lucid::Case::Error::InvalidSubscription) do
      Lucid::Case.subscribe(target, ordered: true) { |_event| nil }
    end

    # assert
    assert_match(/needs as:/, error.message)
  end

  def test_class_subscriber_accepts_ordered
    # arrange
    target = build_post
    received = []
    build_subscriber("Ledger::OnPost") do
      subscribe target, ordered: true
      define_method(:call!) do
        received << event.content[:entry]
        success
      end
    end
    3.times { |index| post(target, index + 1) }

    # act
    job.perform_now(subscriber_id("Ledger::OnPost"))

    # assert
    assert_equal [1, 2, 3], received
    assert_equal record_class.maximum(:id), cursor_value("Ledger::OnPost")
  end

  def test_delivers_pending_events_in_recording_order_and_advances_the_cursor
    # arrange
    target = build_post
    received = []
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |event| received << event.content[:entry] }
    rows = (1..3).map { |entry| post(target, entry) }

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal [1, 2, 3], received
    assert_equal rows.last.id, cursor_value("ledger")
    assert_empty ordered_arguments
  end

  def test_cursor_row_is_created_starting_at_zero_when_nothing_matches
    # arrange
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal 1, cursor_rows
    assert_equal 0, cursor_value("ledger")
  end

  def test_second_event_failing_blocks_the_third_and_retries_from_the_failed_one
    # arrange
    target = build_post
    received = []
    failed = false
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) do |event|
      entry = event.content[:entry]
      if entry == 2 && !failed
        failed = true
        raise ArgumentError, "flaky"
      end
      received << entry
    end
    rows = (1..3).map { |entry| post(target, entry) }
    id = subscriber_id("ledger")

    # act
    job.perform_now(id)

    # assert
    assert_equal [1], received
    assert_equal rows.first.id, cursor_value("ledger")
    assert_equal 1, ordered_arguments.size
  end

  def test_after_the_retry_all_three_are_delivered_in_recording_order
    # arrange
    target = build_post
    received = []
    failed = false
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) do |event|
      entry = event.content[:entry]
      if entry == 2 && !failed
        failed = true
        raise ArgumentError, "flaky"
      end
      received << entry
    end
    rows = (1..3).map { |entry| post(target, entry) }
    id = subscriber_id("ledger")

    # act
    perform_inline { job.perform_later(id) }

    # assert
    assert_equal [1, 2, 3], received
    assert_equal rows.last.id, cursor_value("ledger")
  end

  def test_retry_does_not_redeliver_events_before_the_failed_one
    # arrange
    target = build_post
    calls = Hash.new(0)
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) do |event|
      entry = event.content[:entry]
      calls[entry] += 1
      raise ArgumentError, "flaky" if entry == 2 && calls[entry] < 3
    end
    (1..3).each { |entry| post(target, entry) }

    # act
    perform_inline { job.perform_later(subscriber_id("ledger")) }

    # assert
    assert_equal({ 1 => 1, 2 => 3, 3 => 1 }, calls)
  end

  def test_exhausted_attempts_raise_and_keep_the_cursor_at_the_last_success
    # arrange
    target = build_post
    calls = 0
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) do |event|
      if event.content[:entry] == 2
        calls += 1
        raise ArgumentError, "broken"
      end
    end
    rows = (1..3).map { |entry| post(target, entry) }
    id = subscriber_id("ledger")

    # act
    error = assert_raises(ArgumentError) { perform_inline { job.perform_later(id) } }

    # assert
    assert_equal "broken", error.message
    assert_equal 5, calls
    assert_equal rows.first.id, cursor_value("ledger")
  end

  def test_exhausted_attempts_log_gave_up_with_logging_enabled
    # arrange
    target = build_post
    build_subscriber("Ledger::OnPost") do
      logging :enabled
      subscribe target, ordered: true
      define_method(:call!) { raise ArgumentError, "broken" }
    end
    post(target, 1)
    id = subscriber_id("Ledger::OnPost")

    # act
    assert_raises(ArgumentError) { perform_inline { job.perform_later(id) } }

    # assert
    assert_match(/ERROR.*\[Lucid::Case\].*Ledger::OnPost.*gave up after 5 attempts: ArgumentError/, log.string)
  end

  def test_exhausted_attempts_are_silent_with_logging_disabled
    # arrange
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| raise ArgumentError, "broken" }
    post(target, 1)
    id = subscriber_id("ledger")

    # act
    assert_raises(ArgumentError) { perform_inline { job.perform_later(id) } }

    # assert
    refute_includes log.string, "gave up"
  end

  def test_subscriber_case_returning_failure_counts_as_delivered
    # arrange
    target = build_post
    calls = 0
    build_subscriber("Ledger::OnPost") do
      subscribe target, ordered: true
      define_method(:call!) do
        calls += 1
        failure(:not_billable)
      end
    end
    rows = (1..2).map { |entry| post(target, entry) }

    # act
    job.perform_now(subscriber_id("Ledger::OnPost"))

    # assert
    assert_equal 2, calls
    assert_equal rows.last.id, cursor_value("Ledger::OnPost")
    assert_empty ordered_arguments
  end

  def test_around_delivery_wraps_each_delivery
    # arrange
    wraps = []
    Lucid::Case.configuration.events.around_delivery = lambda do |_context, &block|
      wraps << :before
      block.call
      wraps << :after
    end
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| wraps << :delivery }
    2.times { |index| post(target, index) }

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal %i[before delivery after before delivery after], wraps
  end

  def test_deduplicated_delivery_is_skipped_but_the_cursor_advances
    # arrange
    Lucid::Case.configuration.events.deduplication = :enabled
    target = build_post
    calls = 0
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| calls += 1 }
    rows = (1..3).map { |entry| post(target, entry) }
    id = subscriber_id("ledger")
    job.perform_now(id)
    set_cursor("ledger", 0)

    # act
    job.perform_now(id)

    # assert
    assert_equal 3, calls
    assert_equal 3, delivery_count
    assert_equal rows.last.id, cursor_value("ledger")
  end

  def test_events_that_do_not_match_are_ignored_without_blocking
    # arrange
    target = build_post
    other = build_post("Ledger::Reverse")
    received = []
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |event| received << event.content[:entry] }
    first = post(target, 1)
    post(other, 99)
    second = post(target, 2)
    post(other, 100)

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal [1, 2], received
    assert_equal second.id, cursor_value("ledger")
    assert_operator first.id, :<, second.id
  end

  def test_cursor_does_not_advance_past_the_last_matching_event
    # arrange
    target = build_post
    other = build_post("Ledger::Reverse")
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    matched = post(target, 1)
    post(other, 99)

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal matched.id, cursor_value("ledger")
  end

  def test_each_ordered_subscriber_has_an_independent_cursor
    # arrange
    target = build_post
    first_received = []
    second_received = []
    Lucid::Case.subscribe(target, as: :first, ordered: true) { |event| first_received << event.content[:entry] }
    Lucid::Case.subscribe(target, as: :second, ordered: true) do |event|
      raise ArgumentError, "stuck" if event.content[:entry] == 2

      second_received << event.content[:entry]
    end
    rows = (1..3).map { |entry| post(target, entry) }

    # act
    job.perform_now(subscriber_id("first"))
    job.perform_now(subscriber_id("second"))

    # assert
    assert_equal [1, 2, 3], first_received
    assert_equal [1], second_received
    assert_equal rows.last.id, cursor_value("first")
    assert_equal rows.first.id, cursor_value("second")
  end

  def test_a_purged_row_does_not_block_the_cursor
    # arrange
    target = build_post
    received = []
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |event| received << event.content[:entry] }
    rows = (1..3).map { |entry| post(target, entry) }
    rows[1].destroy

    # act
    job.perform_now(subscriber_id("ledger"))

    # assert
    assert_equal [1, 3], received
    assert_equal rows.last.id, cursor_value("ledger")
  end

  def test_running_the_job_twice_delivers_each_event_once_and_never_regresses_the_cursor
    # arrange
    target = build_post
    received = []
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |event| received << event.content[:entry] }
    rows = (1..3).map { |entry| post(target, entry) }
    id = subscriber_id("ledger")
    job.perform_now(id)
    after_first = cursor_value("ledger")

    # act
    job.perform_now(id)

    # assert
    assert_equal [1, 2, 3], received
    assert_equal rows.last.id, after_first
    assert_equal after_first, cursor_value("ledger")
    assert_equal 1, cursor_rows
  end

  def test_cursor_is_locked_inside_a_transaction_for_each_delivered_event
    # arrange
    Lucid::Case::Events::Cursor.prepend(OrderedLockSpy) unless Lucid::Case::Events::Cursor < OrderedLockSpy
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    3.times { |index| post(target, index) }
    Thread.current[:lucid_lock_log] = []

    # act
    job.perform_now(subscriber_id("ledger"))
    locks = Thread.current[:lucid_lock_log]

    # assert
    assert_operator locks.size, :>=, 3
    assert(locks.all?(&:positive?))
  ensure
    Thread.current[:lucid_lock_log] = nil
  end

  def test_purge_keeps_delivered_rows_above_the_lowest_ordered_cursor
    # arrange
    collect_events
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    rows = (1..3).map { |entry| post(target, entry) }
    record_class.update_all(delivered_at: 8.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal rows.map(&:id), record_class.order(:id).pluck(:id)
  end

  def test_purge_deletes_rows_at_or_below_the_lowest_ordered_cursor
    # arrange
    collect_events
    target = build_post
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_event| nil }
    rows = (1..3).map { |entry| post(target, entry) }
    record_class.update_all(delivered_at: 8.days.ago)
    set_cursor("ledger", rows[1].id)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal [rows[2].id], record_class.order(:id).pluck(:id)
  end

  def test_purge_uses_the_lowest_cursor_among_ordered_subscribers
    # arrange
    collect_events
    target = build_post
    Lucid::Case.subscribe(target, as: :first, ordered: true) { |_event| nil }
    Lucid::Case.subscribe(target, as: :second, ordered: true) { |_event| nil }
    rows = (1..3).map { |entry| post(target, entry) }
    record_class.update_all(delivered_at: 8.days.ago)
    set_cursor("first", rows[2].id)
    set_cursor("second", rows[0].id)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal rows.drop(1).map(&:id), record_class.order(:id).pluck(:id)
  end

  def test_purge_counts_an_ordered_subscriber_without_cursor_as_zero
    # arrange
    collect_events
    target = build_post
    Lucid::Case.subscribe(target, as: :first, ordered: true) { |_event| nil }
    Lucid::Case.subscribe(target, as: :second, ordered: true) { |_event| nil }
    rows = (1..2).map { |entry| post(target, entry) }
    record_class.update_all(delivered_at: 8.days.ago)
    set_cursor("first", rows.last.id)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal rows.map(&:id), record_class.order(:id).pluck(:id)
  end

  def test_purge_without_ordered_subscribers_keeps_the_previous_behavior
    # arrange
    collect_events
    target = build_post
    Lucid::Case.subscribe(target, as: :mailer) { |_event| nil }
    (1..2).each { |entry| post(target, entry) }
    record_class.update_all(delivered_at: 8.days.ago)

    # act
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 0, record_class.count
  end
end
