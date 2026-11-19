require "test_helper"

class EventsDeliveryJobTest < OutboxTest
  def job
    Lucid::Case::Events::DeliveryJob
  end

  def setup
    super
    hold_events
  end

  def record_event(command = approve_command, **attributes)
    command.call(enrollment: Order.create!(status: "pending"), **attributes)
    record_class.order(:id).last
  end

  def subscriber_id(name)
    Lucid::Case::Events::Registry.subscriptions.find { |subscription| subscription.subscriber_id.to_s == name }.subscriber_id
  end

  def test_block_subscriber_receives_event_with_reloaded_record
    # arrange
    target = approve_command
    received = []
    Lucid::Case.subscribe(target, as: :listener) { |event| received << event }
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("listener"))

    # assert
    event = received.sole
    assert_kind_of Lucid::Case::Event, event
    assert_equal row.uuid, event.id
    assert_equal Order.last, event.content[:enrollment]
    assert_equal "enrollment.approve", event.name
  end

  def test_class_subscriber_is_called_with_event_keyword
    # arrange
    target = approve_command
    received = []
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        received << event
        success
      end
    end
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_equal [row.uuid], received.map(&:id)
    assert_equal Order.last, received.first.content[:enrollment]
  end

  def test_context_is_restored_by_around_delivery_in_the_job
    # arrange
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }
    Lucid::Case.configuration.events.around_delivery = lambda do |context, &block|
      Thread.current[:lucid_test_tenant] = context[:tenant]
      block.call
    ensure
      Thread.current[:lucid_test_tenant] = nil
    end
    target = approve_command
    seen = []
    Lucid::Case.subscribe(target, as: :tenant_spy) do |event|
      seen << [Thread.current[:lucid_test_tenant], event.context]
    end
    row = record_event(target)
    Thread.current[:lucid_test_tenant] = nil

    # act
    job.perform_now(row.uuid, subscriber_id("tenant_spy"))

    # assert
    assert_equal [["alfa", { tenant: "alfa" }]], seen
  end

  def test_missing_row_is_discarded_without_calling_the_subscriber
    # arrange
    target = approve_command
    called = []
    Lucid::Case.subscribe(target, as: :listener) { |event| called << event }
    row = record_event(target)
    id = subscriber_id("listener")
    record_class.delete_all

    # act
    job.perform_now(row.uuid, id)

    # assert
    assert_empty called
  end

  def test_missing_row_logs_error_with_subscriber_logging_enabled
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      logging :enabled
      subscribe target
      define_method(:call!) { success }
    end
    row = record_event(target)
    record_class.delete_all

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_match(/ERROR.*\[Lucid::Case\].*event id=#{row.uuid} not found \(purged\) for Billing::OnApproved/, log.string)
  end

  def test_missing_row_logs_with_global_logging_for_block_subscriber
    # arrange
    Lucid::Case.configuration.logging = :enabled
    target = approve_command
    Lucid::Case.subscribe(target, as: :listener) { |_event| nil }
    row = record_event(target)
    record_class.delete_all

    # act
    job.perform_now(row.uuid, subscriber_id("listener"))

    # assert
    assert_match(/event id=#{row.uuid} not found \(purged\) for listener/, log.string)
  end

  def test_missing_row_is_silent_with_logging_disabled
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :listener) { |_event| nil }
    row = record_event(target)
    id = subscriber_id("listener")
    record_class.delete_all

    # act
    job.perform_now(row.uuid, id)

    # assert
    refute_includes log.string, "not found"
  end

  def test_failing_subscriber_is_retried_until_delivery_attempts_then_raises
    # arrange
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :broken) do |_event|
      calls += 1
      raise ArgumentError, "broken"
    end
    row = record_event(target)
    id = subscriber_id("broken")

    # act
    error = assert_raises(ArgumentError) do
      perform_inline { job.perform_later(row.uuid, id) }
    end

    # assert
    assert_equal "broken", error.message
    assert_equal 5, calls
  end

  def test_first_failure_enqueues_a_retry_instead_of_raising
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :broken) { |_event| raise "broken" }
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("broken"))

    # assert
    assert_equal 1, delivery_arguments.size
  end

  def test_subscriber_succeeding_on_retry_stops_retrying
    # arrange
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :flaky) do |_event|
      calls += 1
      raise "flaky" if calls < 3
    end
    row = record_event(target)

    # act
    perform_inline { job.perform_later(row.uuid, subscriber_id("flaky")) }

    # assert
    assert_equal 3, calls
  end

  def test_exhausted_attempts_log_error_with_subscriber_logging_enabled
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      logging :enabled
      subscribe target
      define_method(:call!) { raise ArgumentError, "broken" }
    end
    row = record_event(target)
    id = subscriber_id("Billing::OnApproved")

    # act
    assert_raises(ArgumentError) { perform_inline { job.perform_later(row.uuid, id) } }

    # assert
    assert_match(
      /ERROR.*\[Lucid::Case\].*event "enrollment.approve" id=#{row.uuid} delivery to Billing::OnApproved gave up after 5 attempts: ArgumentError/,
      log.string
    )
  end

  def test_exhausted_attempts_are_silent_with_logging_disabled
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :broken) { |_event| raise ArgumentError, "broken" }
    row = record_event(target)
    id = subscriber_id("broken")

    # act
    assert_raises(ArgumentError) { perform_inline { job.perform_later(row.uuid, id) } }

    # assert
    refute_includes log.string, "gave up"
  end

  def test_subscriber_case_returning_failure_is_delivered_without_retry
    # arrange
    target = approve_command
    calls = 0
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        calls += 1
        failure(:not_billable)
      end
    end
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_equal 1, calls
    assert_empty delivery_arguments
  end

  def test_failing_subscriber_does_not_affect_the_other_subscribers_job
    # arrange
    target = approve_command
    good_calls = 0
    bad_calls = 0
    Lucid::Case.subscribe(target, as: :good) { |_event| good_calls += 1 }
    Lucid::Case.subscribe(target, as: :bad) do |_event|
      bad_calls += 1
      raise "bad"
    end
    Lucid::Case.configuration.events.transport = :active_job
    record_event(target)
    jobs = delivery_arguments.sort_by { |_uuid, subscriber| subscriber.to_s == "bad" ? 1 : 0 }
    clear_enqueued_jobs

    # act
    assert_raises(RuntimeError) do
      perform_inline do
        jobs.each { |uuid, subscriber| job.perform_later(uuid, subscriber) }
      end
    end

    # assert
    assert_equal 2, jobs.size
    assert_equal 1, good_calls
    assert_equal 5, bad_calls
  end

  def test_relay_to_delivery_end_to_end_runs_each_subscriber_once
    # arrange
    Lucid::Case.configuration.events.transport = :active_job
    target = approve_command
    called = []
    Lucid::Case.subscribe(target, as: :first) { |event| called << [:first, event.content[:enrollment].class] }
    Lucid::Case.subscribe(target, as: :second) { |event| called << [:second, event.content[:enrollment].class] }

    # act
    perform_inline { target.call(enrollment: Order.create!(status: "a")) }

    # assert
    assert_equal [[:first, Order], [:second, Order]], called.sort_by(&:first)
  end
end
