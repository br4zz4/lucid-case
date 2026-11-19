require "test_helper"

class EventsRecordingTest < EventsTest
  def approve_command(&block)
    build_command("Enrollment::Approve") do
      attributes :enrollment
      define_method(:call!) { success(enrollment: enrollment) }
      class_eval(&block) if block
    end
  end

  def test_default_recording_is_disabled
    # assert
    assert_equal :disabled, Lucid::Case::Events::Configuration.new.recording
  end

  def test_disabled_global_records_nothing
    # arrange
    with_events(recording: :disabled)
    command = approve_command
    spy(command)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty events
  end

  def test_command_events_enabled_overrides_disabled_global
    # arrange
    with_events(recording: :disabled)
    command = approve_command { events :enabled }
    spy(command)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, events.size
    assert command.events_recording?
  end

  def test_command_events_disabled_overrides_enabled_global
    # arrange
    command = approve_command { events :disabled }
    spy(command)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty events
    refute command.events_recording?
  end

  def test_events_macro_rejects_invalid_value
    # act / assert
    assert_raises(ArgumentError) { approve_command { events :sometimes } }
  end

  def test_events_macro_in_query_raises
    # act / assert
    assert_raises(Error::SideEffectInQuery) do
      build_case("Dashboard::Evolution", parent: Lucid::Case::Query) { events :enabled }
    end
  end

  def test_case_event_on_success
    # arrange
    command = approve_command
    spy(command)
    order = Order.create!(status: "pending")

    # act
    command.call(enrollment: order)

    # assert
    event = events.first
    assert_equal 1, events.size
    assert_kind_of Lucid::Case::Event, event
    assert_equal :case, event.kind
    assert_equal "enrollment.approve", event.name
    assert_equal "Enrollment::Approve", event.source
    assert_equal :ok, event.type
    assert event.success?
    assert_nil event.step
  end

  def test_event_metadata
    # arrange
    command = approve_command
    spy(command)

    # act
    command.call(enrollment: Order.create!(status: "pending"))

    # assert
    event = events.first
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, event.id)
    assert_kind_of Time, event.occurred_at
  end

  def test_event_content_and_input_reload_records
    # arrange
    command = approve_command
    spy(command)
    order = Order.create!(status: "pending")

    # act
    command.call(enrollment: order)

    # assert
    event = events.first
    assert_equal order, event.content[:enrollment]
    refute_same order, event.content[:enrollment]
    assert_equal order, event.input[:enrollment]
  end

  def test_input_is_filtered
    # arrange
    Lucid::Case.configuration.filter_parameters = [:password]
    command = build_command("Users::Create") do
      attributes :params
      define_method(:call!) { success }
    end
    spy(command)

    # act
    command.call(params: { email: "a@x.com", password: "123456" })

    # assert
    assert_equal "[FILTERED]", events.first.input[:params][:password]
    assert_equal "a@x.com", events.first.input[:params][:email]
  end

  def test_event_is_delivered_only_after_outer_commit
    # arrange
    command = approve_command
    spy(command)
    order = Order.create!(status: "pending")
    inside = nil

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      inside = events.dup
    end

    # assert
    assert_empty inside
    assert_equal 1, events.size
  end

  def test_outer_rollback_after_success_delivers_nothing
    # arrange
    command = approve_command
    spy(command)
    order = Order.create!(status: "pending")

    # act
    ActiveRecord::Base.transaction do
      command.call(enrollment: order)
      raise ActiveRecord::Rollback
    end

    # assert
    assert_empty events
  end

  def test_failure_records_case_event_with_failure_type
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) { failure(:card_declined, reason: "limit") }
    end
    spy(command, on: :any)

    # act
    command.call

    # assert
    event = events.first
    assert_equal 1, events.size
    assert_equal :card_declined, event.type
    refute event.success?
    assert_equal "limit", event.content[:reason]
  end

  def test_failure_event_survives_case_rollback
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        User.create!(name: "Ana")
        failure(:card_declined)
      end
    end
    spy(command, on: :any)
    user_count_when_delivered = nil
    Lucid::Case.subscribe(command, on: :any, as: :counter) { |_event| user_count_when_delivered = User.count }

    # act
    command.call

    # assert
    assert_equal 0, User.count
    assert_equal 0, user_count_when_delivered
    assert_equal :card_declined, events.first.type
  end

  def test_failure_event_waits_for_outer_commit
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    spy(command, on: :any)
    inside = nil

    # act
    ActiveRecord::Base.transaction do
      command.call
      inside = events.dup
    end

    # assert
    assert_empty inside
    assert_equal 1, events.size
  end

  def test_caught_exception_records_failure_event
    # arrange
    command = build_command("Payment::Charge") do
      catch(Timeout::Error) { failure(:timeout) }
      define_method(:call!) { raise Timeout::Error }
    end
    spy(command, on: :any)

    # act
    command.call

    # assert
    assert_equal 1, events.size
    assert_equal :timeout, events.first.type
  end

  def test_uncaught_exception_records_nothing_and_raises
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { raise "boom" } }
    spy(command, on: :any)

    # act / assert
    assert_raises(RuntimeError) { command.call }
    assert_empty events
  end

  def test_invalid_attributes_records_failure_event
    # arrange
    command = build_command("Users::Create") do
      attributes :email
      validates :email, presence: true
      define_method(:call!) { success }
    end
    spy(command, on: :any)

    # act
    command.call(email: nil)

    # assert
    assert_equal 1, events.size
    assert_equal :invalid_attributes, events.first.type
  end

  def test_query_never_records_case_event
    # arrange
    query = build_case("Dashboard::Evolution", parent: Lucid::Case::Query) { define_method(:call!) { success } }
    seen = []
    Lucid::Case.subscribe(:anything, as: :any_custom) { |event| seen << event }

    # act
    query.call

    # assert
    assert_empty seen
    assert_empty events
  end

  def test_subscriber_called_directly_records_nothing
    # arrange
    target = approve_command
    subscriber = build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) { success }
    end
    spy(target, as: :target_spy, on: :any)

    # act
    subscriber.call(event: Lucid::Case::Event.new(id: "e1", kind: :case, name: "enrollment.approve", source: "Enrollment::Approve", type: :ok, occurred_at: Time.now))

    # assert
    assert_empty events
  end

  def test_event_payload_replaces_content_and_input
    # arrange
    command = build_command("Users::Create") do
      attributes :params
      event_payload { |result| { user_id: result[:user].id } }
      define_method(:call!) { success(user: User.create!(name: "Ana")) }
    end
    spy(command)

    # act
    command.call(params: { password: "x" })

    # assert
    assert_equal({ user_id: User.first.id }, events.first.content)
    assert_equal({}, events.first.input)
  end

  def test_unserializable_content_raises_and_rolls_back
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        User.create!(name: "Ana")
        success(callback: -> {})
      end
    end
    spy(command)

    # act / assert
    assert_raises(Error::UnserializableEvent) { command.call }
    assert_equal 0, User.count
    assert_empty events
  end

  def test_unsaved_record_is_unserializable
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) { success(user: User.new(name: "Ana")) }
    end
    spy(command)

    # act / assert
    assert_raises(Error::UnserializableEvent) { command.call }
    assert_empty events
  end

  def test_unserializable_without_transaction_keeps_data
    # arrange
    command = build_command("Payment::Charge") do
      transaction :disabled
      define_method(:call!) do
        User.create!(name: "Ana")
        success(callback: -> {})
      end
    end
    spy(command)

    # act / assert
    assert_raises(Error::UnserializableEvent) { command.call }
    assert_equal 1, User.count
    assert_empty events
  end

  def test_event_payload_avoids_unserializable_content
    # arrange
    command = build_command("Payment::Charge") do
      event_payload { |_result| { ok: true } }
      define_method(:call!) { success(callback: -> {}) }
    end
    spy(command)

    # act
    command.call

    # assert
    assert_equal({ ok: true }, events.first.content)
  end

  def test_custom_event_emitted_before_case_event
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        success
      end
    end
    spy(:credit_limit_reached, as: :custom_spy)
    spy(command, as: :case_spy)
    order = []
    Lucid::Case.subscribe(:credit_limit_reached, as: :order_custom) { |_e| order << :custom }
    Lucid::Case.subscribe(command, as: :order_case) { |_e| order << :case }

    # act
    command.call

    # assert
    custom = events.find { |event| event.kind == :custom }
    assert_equal 2, events.size
    assert_equal "credit_limit_reached", custom.name
    assert_equal({ customer_id: 9 }, custom.content)
    assert_equal({}, custom.input)
    assert_nil custom.type
    assert_equal "Payment::Charge", custom.source
    assert_equal %i[custom case], order
  end

  def test_emit_accepts_string_name
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit("credit_limit_reached")
        success
      end
    end
    spy(:credit_limit_reached)

    # act
    command.call

    # assert
    assert_equal "credit_limit_reached", events.first.name
  end

  def test_emit_is_noop_when_recording_is_off
    # arrange
    with_events(recording: :disabled)
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end
    spy(:credit_limit_reached)

    # act
    result = command.call

    # assert
    assert result.success?
    assert_empty events
  end

  def test_emit_disappears_with_case_failure
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        failure(:card_declined)
      end
    end
    spy(:credit_limit_reached, as: :custom_spy)
    spy(command, on: :any, as: :case_spy)

    # act
    command.call

    # assert
    assert_equal [:case], events.map(&:kind)
    assert_equal :card_declined, events.first.type
  end

  def test_emit_disappears_with_outer_rollback
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end
    spy(:credit_limit_reached)

    # act
    ActiveRecord::Base.transaction do
      command.call
      raise ActiveRecord::Rollback
    end

    # assert
    assert_empty events
  end

  def test_emit_in_query_raises
    # arrange
    query = build_case("Dashboard::Evolution", parent: Lucid::Case::Query) do
      define_method(:call!) do
        emit(:something)
        success
      end
    end

    # act / assert
    assert_raises(Error::EmitOutsideCommand) { query.call }
  end

  def test_emit_in_subscriber_raises
    # arrange
    subscriber = build_subscriber("Billing::OnApproved") do
      define_method(:call!) do
        emit(:something)
        success
      end
    end
    event = Lucid::Case::Event.new(id: "e1", kind: :case, name: "x", source: "X", type: :ok, occurred_at: Time.now)

    # act / assert
    assert_raises(Error::EmitOutsideCommand) { subscriber.call(event: event) }
  end
end
