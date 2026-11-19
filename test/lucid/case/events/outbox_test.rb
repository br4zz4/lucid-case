require "test_helper"

class EventsOutboxTest < OutboxTest
  def setup
    super
    hold_events
  end

  def test_success_records_one_case_row
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    command.call(enrollment: order)

    # assert
    row = record_class.sole
    assert_match(/\A#{UUID}\z/, row.uuid)
    assert_equal "case", row.kind
    assert_equal "enrollment.approve", row.name
    assert_equal "Enrollment::Approve", row.source
    assert_nil row.step
    assert_equal "ok", row.result_type
    assert row.success
    refute_nil row.occurred_at
    assert_nil row.delivered_at
    assert_nil row.claimed_at
  end

  def test_row_rebuilds_the_event_with_reloaded_record
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }
    transport = collect_events
    command.call(enrollment: order)

    # act
    event = record_class.sole.to_event

    # assert
    published = transport.published.first
    assert_kind_of Lucid::Case::Event, event
    assert_equal published.id, event.id
    assert_equal order, event.content[:enrollment]
    refute_same order, event.content[:enrollment]
    assert_equal({ tenant: "alfa" }, event.context)
    assert_equal :ok, event.type
    assert_equal :case, event.kind
    assert_equal published, event
  end

  def test_input_is_filtered_in_the_stored_event
    # arrange
    Lucid::Case.configuration.filter_parameters = [:password]
    command = build_command("Users::Create") do
      attributes :params
      define_method(:call!) { success }
    end

    # act
    command.call(params: { email: "a@x.com", password: "123456" })

    # assert
    event = record_class.sole.to_event
    assert_equal "[FILTERED]", event.input[:params][:password]
    assert_equal "a@x.com", event.input[:params][:email]
  end

  def test_row_persists_context_column
    # arrange
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal({ "tenant" => "alfa" }, record_class.sole.context)
  end

  def test_failure_is_recorded_after_the_case_rollback
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        User.create!(name: "Ana")
        failure(:card_declined)
      end
    end

    # act
    command.call

    # assert
    row = record_class.sole
    assert_equal 0, User.count
    assert_equal "card_declined", row.result_type
    refute row.success
    assert_equal "case", row.kind
  end

  def test_uncaught_exception_records_nothing
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { raise "boom" } }

    # act / assert
    assert_raises(RuntimeError) { command.call }
    assert_equal 0, record_class.count
  end

  def test_caught_exception_records_failure
    # arrange
    command = build_command("Payment::Charge") do
      catch(Timeout::Error) { failure(:timeout) }
      define_method(:call!) { raise Timeout::Error }
    end

    # act
    command.call

    # assert
    assert_equal "timeout", record_class.sole.result_type
  end

  def test_outer_rollback_removes_the_row
    # arrange
    command = approve_command
    order = Order.create!(status: "a")

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      raise ActiveRecord::Rollback
    end

    # assert
    assert_equal 0, record_class.count
  end

  def test_row_is_written_inside_the_same_transaction
    # arrange
    command = approve_command
    order = Order.create!(status: "a")
    seen = nil

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      seen = record_class.count
      raise ActiveRecord::Rollback
    end

    # assert
    assert_equal 1, seen
  end

  def test_failure_row_is_removed_by_outer_rollback
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }

    # act
    ActiveRecord::Base.transaction do
      command.call
      raise ActiveRecord::Rollback
    end

    # assert
    assert_equal 0, record_class.count
  end

  def test_emit_records_custom_and_case_rows
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        success
      end
    end

    # act
    command.call

    # assert
    custom = record_class.find_by!(kind: "custom")
    assert_equal 2, record_class.count
    assert_equal "credit_limit_reached", custom.name
    assert_nil custom.result_type
    assert_equal "payment.charge", record_class.find_by!(kind: "case").name
    assert_equal({ customer_id: 9 }, custom.to_event.content)
  end

  def test_emit_disappears_with_the_rollback
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        failure(:card_declined)
      end
    end

    # act
    command.call

    # assert
    assert_equal ["case"], record_class.pluck(:kind)
  end

  def test_step_row_is_written_only_when_assigned
    # arrange
    command = build_command("Order::Place") do
      step(:reserve_stock) { continue(reserved: true) }
      step(:charge_card) { success }
    end
    spy(command, step: :reserve_stock)

    # act
    command.call

    # assert
    step_row = record_class.find_by!(kind: "step")
    assert_equal "reserve_stock", step_row.step
    assert_equal "order.place", step_row.name
    assert_equal 2, record_class.count
  end

  def test_step_without_subscription_records_no_step_row
    # arrange
    command = build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end

    # act
    command.call

    # assert
    assert_equal ["case"], record_class.pluck(:kind)
  end

  def test_unserializable_payload_raises_and_rolls_back
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        User.create!(name: "Ana")
        success(callback: -> {})
      end
    end

    # act / assert
    assert_raises(Error::UnserializableEvent) { command.call }
    assert_equal 0, User.count
    assert_equal 0, record_class.count
  end

  def test_recording_disabled_writes_nothing
    # arrange
    with_events(store: :outbox, recording: :disabled)

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 0, record_class.count
  end

  def test_case_level_events_enabled_records_with_global_disabled
    # arrange
    with_events(store: :outbox, recording: :disabled)
    command = build_command("Payment::Charge") do
      events :enabled
      define_method(:call!) { success }
    end

    # act
    command.call

    # assert
    assert_equal 1, record_class.count
  end

  def test_record_table_name_follows_configuration
    # arrange
    default = record_class.table_name
    Lucid::Case.configuration.events.table_name = "custom_events"

    # act
    custom = record_class.table_name

    # assert
    assert_equal "lucid_case_events", default
    assert_equal "custom_events", custom
  end

  def test_custom_table_name_is_used_for_recording_relay_and_purge
    # arrange
    ActiveRecord::Base.connection.create_table(:custom_events, force: true) do |t|
      t.string :uuid, null: false
      t.string :kind, null: false
      t.string :name, null: false
      t.string :source
      t.string :step
      t.string :result_type
      t.boolean :success, null: false, default: true
      t.json :payload, null: false
      t.json :context, null: false
      t.datetime :occurred_at, null: false
      t.datetime :claimed_at
      t.string :claim_token
      t.datetime :delivered_at
      t.datetime :created_at, null: false
    end
    Lucid::Case.configuration.events.table_name = "custom_events"
    record_class.reset_column_information
    transport = collect_events

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))
    travel 8.days
    Lucid::Case::Events.relay_pending

    # assert
    assert_equal 1, transport.published.size
    assert_equal 0, record_class.count
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM lucid_case_events")
  ensure
    ActiveRecord::Base.connection.drop_table(:custom_events, if_exists: true)
  end
end
