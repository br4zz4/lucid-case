require "test_helper"

class EventsDeduplicationTest < OutboxTest
  def job
    Lucid::Case::Events::DeliveryJob
  end

  def setup
    super
    hold_events
    Lucid::Case.configuration.events.deduplication = :enabled
  end

  def record_event(command)
    command.call(enrollment: Order.create!(status: "pending"))
    record_class.order(:id).last
  end

  def subscriber_id(name)
    Lucid::Case::Events::Registry.subscriptions.find { |subscription| subscription.subscriber_id.to_s == name }.subscriber_id
  end

  def test_same_job_twice_runs_the_block_subscriber_once
    # arrange
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :mailer) { |_event| calls += 1 }
    row = record_event(target)
    id = subscriber_id("mailer")

    # act
    2.times { job.perform_now(row.uuid, id) }

    # assert
    assert_equal 1, calls
    assert_equal 1, delivery_count
  end

  def test_same_job_twice_runs_the_class_subscriber_once
    # arrange
    target = approve_command
    calls = 0
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        calls += 1
        success
      end
    end
    row = record_event(target)
    id = subscriber_id("Billing::OnApproved")

    # act
    2.times { job.perform_now(row.uuid, id) }

    # assert
    assert_equal 1, calls
    assert_equal 1, delivery_count
  end

  def test_different_subscribers_of_the_same_event_each_run_once
    # arrange
    target = approve_command
    called = []
    Lucid::Case.subscribe(target, as: :first) { |_event| called << :first }
    Lucid::Case.subscribe(target, as: :second) { |_event| called << :second }
    row = record_event(target)
    ids = %w[first second].map { |name| subscriber_id(name) }

    # act
    2.times { ids.each { |id| job.perform_now(row.uuid, id) } }

    # assert
    assert_equal %i[first second], called.sort
    assert_equal 2, delivery_count
  end

  def test_the_mark_stores_event_uuid_and_subscriber
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :mailer) { |_event| nil }
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("mailer"))

    # assert
    stored = ActiveRecord::Base.connection.select_rows("SELECT event_uuid, subscriber FROM lucid_case_deliveries")
    assert_equal [[row.uuid, "mailer"]], stored
  end

  def test_transactional_subscriber_failure_rolls_back_the_mark
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) { raise ArgumentError, "boom" }
    end
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_equal 0, delivery_count
    assert_equal 1, delivery_arguments.size
  end

  def test_transactional_subscriber_runs_again_on_the_retry
    # arrange
    target = approve_command
    calls = 0
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        calls += 1
        raise ArgumentError, "flaky" if calls == 1

        success
      end
    end
    row = record_event(target)
    id = subscriber_id("Billing::OnApproved")

    # act
    perform_inline { job.perform_later(row.uuid, id) }

    # assert
    assert_equal 2, calls
    assert_equal 1, delivery_count
  end

  def test_transactional_subscriber_returning_failure_keeps_the_mark
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
    id = subscriber_id("Billing::OnApproved")

    # act
    2.times { job.perform_now(row.uuid, id) }

    # assert
    assert_equal 1, calls
    assert_equal 1, delivery_count
    assert_empty delivery_arguments
  end

  def test_block_subscriber_failure_removes_the_mark
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :mailer) { |_event| raise ArgumentError, "boom" }
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("mailer"))

    # assert
    assert_equal 0, delivery_count
    assert_equal 1, delivery_arguments.size
  end

  def test_block_subscriber_runs_again_on_the_retry
    # arrange
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :mailer) do |_event|
      calls += 1
      raise ArgumentError, "flaky" if calls == 1
    end
    row = record_event(target)

    # act
    perform_inline { job.perform_later(row.uuid, subscriber_id("mailer")) }

    # assert
    assert_equal 2, calls
    assert_equal 1, delivery_count
  end

  def test_block_subscriber_success_keeps_the_mark
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :mailer) { |_event| nil }
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("mailer"))

    # assert
    assert_equal 1, delivery_count
    assert_empty delivery_arguments
  end

  def test_non_transactional_subscriber_marks_before_invoking
    # arrange
    target = approve_command
    seen = []
    build_subscriber("Billing::OnApproved") do
      transaction :disabled
      subscribe target
      define_method(:call!) do
        seen << ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM lucid_case_deliveries").to_i
        success
      end
    end
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_equal [1], seen
    assert_equal 1, delivery_count
  end

  def test_non_transactional_subscriber_failure_removes_the_mark
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      transaction :disabled
      subscribe target
      define_method(:call!) { raise ArgumentError, "boom" }
    end
    row = record_event(target)

    # act
    job.perform_now(row.uuid, subscriber_id("Billing::OnApproved"))

    # assert
    assert_equal 0, delivery_count
    assert_equal 1, delivery_arguments.size
  end

  def test_non_transactional_subscriber_runs_again_on_the_retry
    # arrange
    target = approve_command
    calls = 0
    build_subscriber("Billing::OnApproved") do
      transaction :disabled
      subscribe target
      define_method(:call!) do
        calls += 1
        raise ArgumentError, "flaky" if calls == 1

        success
      end
    end
    row = record_event(target)
    id = subscriber_id("Billing::OnApproved")

    # act
    perform_inline { job.perform_later(row.uuid, id) }

    # assert
    assert_equal 2, calls
    assert_equal 1, delivery_count
  end

  def test_disabled_deduplication_does_not_touch_the_table_and_runs_twice
    # arrange
    Lucid::Case.configuration.events.deduplication = :disabled
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :mailer) { |_event| calls += 1 }
    row = record_event(target)
    id = subscriber_id("mailer")
    connection = ActiveRecord::Base.connection

    # act
    begin
      connection.drop_table :lucid_case_deliveries
      2.times { job.perform_now(row.uuid, id) }
    ensure
      connection.create_table :lucid_case_deliveries, force: true do |t|
        t.string :event_uuid, null: false
        t.string :subscriber, null: false
        t.datetime :created_at, null: false
      end
      connection.add_index :lucid_case_deliveries, %i[event_uuid subscriber], unique: true
    end

    # assert
    assert_equal 2, calls
    assert_equal 0, delivery_count
  end

  def test_record_not_unique_raised_by_a_block_subscriber_is_not_treated_as_duplicate
    # arrange
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :mailer) do |_event|
      calls += 1
      raise ActiveRecord::RecordNotUnique, "from the body"
    end
    row = record_event(target)
    id = subscriber_id("mailer")

    # act
    error = assert_raises(ActiveRecord::RecordNotUnique) do
      perform_inline { job.perform_later(row.uuid, id) }
    end

    # assert
    assert_equal "from the body", error.message
    assert_equal 5, calls
    assert_equal 0, delivery_count
  end

  def test_record_not_unique_raised_by_a_class_subscriber_is_not_treated_as_duplicate
    # arrange
    target = approve_command
    calls = 0
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        calls += 1
        raise ActiveRecord::RecordNotUnique, "from the body"
      end
    end
    row = record_event(target)
    id = subscriber_id("Billing::OnApproved")

    # act
    error = assert_raises(ActiveRecord::RecordNotUnique) do
      perform_inline { job.perform_later(row.uuid, id) }
    end

    # assert
    assert_equal "from the body", error.message
    assert_equal 5, calls
    assert_equal 0, delivery_count
  end

  def test_block_subscription_without_as_raises_with_deduplication_enabled
    # arrange
    target = approve_command

    # act
    error = assert_raises(Lucid::Case::Error::InvalidSubscription) do
      Lucid::Case.subscribe(target) { |_event| nil }
    end

    # assert
    assert_match(/needs as:/, error.message)
  end

  def test_custom_deliveries_table_name_is_used
    # arrange
    connection = ActiveRecord::Base.connection
    connection.create_table :custom_deliveries, force: true do |t|
      t.string :event_uuid, null: false
      t.string :subscriber, null: false
      t.datetime :created_at, null: false
    end
    connection.add_index :custom_deliveries, %i[event_uuid subscriber], unique: true
    Lucid::Case.configuration.events.deliveries_table_name = "custom_deliveries"
    target = approve_command
    calls = 0
    Lucid::Case.subscribe(target, as: :mailer) { |_event| calls += 1 }
    row = record_event(target)
    id = subscriber_id("mailer")

    # act
    2.times { job.perform_now(row.uuid, id) }

    # assert
    assert_equal 1, calls
    assert_equal 1, delivery_count("custom_deliveries")
    assert_equal 0, delivery_count("lucid_case_deliveries")
  ensure
    connection.drop_table :custom_deliveries, if_exists: true
  end
end
