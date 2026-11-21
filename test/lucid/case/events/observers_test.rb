require "test_helper"

class EventsObserversTest < EventsTest
  Call = Struct.new(:event, :command, :result, :open_transactions)

  class Collector
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(event:, command:, result:)
      @calls << Call.new(event, command, result, ActiveRecord::Base.connection.open_transactions)
    end
  end

  def observers
    Lucid::Case.configuration.events.observers
  end

  def observe
    collector = Collector.new
    observers << collector
    collector
  end

  def approve_command(&block)
    build_command("Enrollment::Approve") do
      attributes :enrollment
      define_method(:call!) { success(enrollment: enrollment) }
      class_eval(&block) if block
    end
  end

  def test_default_observers_is_empty
    # assert
    assert_equal [], Lucid::Case::Events::Configuration.new.observers
  end

  def test_success_notifies_observer_inside_the_transaction
    # arrange
    collector = observe
    command = approve_command
    order = Order.create!(status: "pending")
    baseline = ActiveRecord::Base.connection.open_transactions

    # act
    result = command.call(enrollment: order)

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    assert call.result.success?
    assert_equal result.content, call.result.content
    assert_equal "enrollment.approve", call.event.name
    assert_equal :case, call.event.kind
    assert_kind_of Lucid::Case::Event, call.event
    assert_kind_of command, call.command
    assert_equal order, call.command.enrollment
    assert_same order, call.result.content[:enrollment]
    assert_operator call.open_transactions, :>, baseline
  end

  def test_success_observer_sees_the_command_writes_before_commit
    # arrange
    seen = []
    observers << ->(event:, command:, result:) { seen << User.count }
    command = build_command("Users::Create") { define_method(:call!) { success(user: User.create!(name: "Ana")) } }

    # act
    command.call

    # assert
    assert_equal [1], seen
  end

  def test_typed_failure_notifies_observer_after_rollback
    # arrange
    collector = observe
    command = build_command("Members::Remove") do
      define_method(:call!) do
        User.create!(name: "Ana")
        failure(:last_owner)
      end
    end
    seen = []
    observers << ->(event:, command:, result:) { seen << User.count }
    baseline = ActiveRecord::Base.connection.open_transactions

    # act
    command.call

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    refute call.result.success?
    assert_equal :last_owner, call.result.type
    assert_equal :last_owner, call.event.type
    assert_equal [0], seen
    assert_equal baseline, call.open_transactions
  end

  def test_fail_if_guard_notifies_with_type_and_errors
    # arrange
    collector = observe
    command = build_command("Members::Remove") do
      fail_if :last_owner?
      define_method(:last_owner?) { true }
      define_method(:call!) { success }
    end

    # act
    command.call

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    assert_equal :last_owner, call.result.type
    assert_kind_of Array, call.result[:errors]
    refute_empty call.result[:errors]
  end

  def test_fail_with_notifies_with_type
    # arrange
    collector = observe
    command = build_command("Members::Remove") do
      define_method(:call!) { fail_with(:x, plan: []) }
    end

    # act
    command.call

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    assert_equal :x, call.result.type
    assert_kind_of Array, call.result[:errors]
    refute_empty call.result[:errors]
    assert_equal [], call.result[:plan]
  end

  def test_validates_notifies_invalid_attributes_with_errors
    # arrange
    collector = observe
    command = build_command("Users::Create") do
      attributes :email
      validates :email, presence: true
      define_method(:call!) { success }
    end

    # act
    command.call(email: nil)

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    assert_equal :invalid_attributes, call.result.type
    refute_empty call.result[:errors]
  end

  def test_exception_does_not_notify
    # arrange
    collector = observe
    command = build_command("Payment::Charge") { define_method(:call!) { raise "boom" } }

    # act / assert
    assert_raises(RuntimeError) { command.call }
    assert_empty collector.calls
  end

  def test_caught_exception_notifies_failure
    # arrange
    collector = observe
    command = build_command("Payment::Charge") do
      catch(Timeout::Error) { failure(:timeout) }
      define_method(:call!) { raise Timeout::Error }
    end

    # act
    command.call

    # assert
    assert_equal [:timeout], collector.calls.map { |call| call.result.type }
  end

  def test_notifies_with_recording_disabled
    # arrange
    with_events(recording: :disabled)
    collector = observe
    command = approve_command
    spy(command)

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, collector.calls.size
    assert_equal "enrollment.approve", collector.calls.first.event.name
    assert_empty events
  end

  def test_notifies_with_inline_store
    # arrange
    with_events(store: :inline)
    collector = observe

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, collector.calls.size
  end

  def test_notifies_with_outbox_store
    # arrange
    with_events(store: :outbox)
    Lucid::Case.configuration.events.table_name = "lucid_case_events"
    collector = observe

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, collector.calls.size
    assert collector.calls.first.result.success?
  end

  def test_notifies_with_outbox_store_and_recording_disabled
    # arrange
    with_events(store: :outbox, recording: :disabled)
    collector = observe

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, collector.calls.size
  end

  def test_command_events_disabled_turns_observers_off
    # arrange
    collector = observe
    command = approve_command { events :disabled }

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_empty collector.calls
  end

  def test_command_events_disabled_turns_observers_off_on_failure
    # arrange
    collector = observe
    command = build_command("Payment::Charge") do
      events :disabled
      define_method(:call!) { failure(:card_declined) }
    end

    # act
    command.call

    # assert
    assert_empty collector.calls
  end

  def test_command_events_enabled_notifies_with_recording_disabled
    # arrange
    with_events(recording: :disabled)
    collector = observe
    command = approve_command { events :enabled }

    # act
    command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal 1, collector.calls.size
  end

  def test_raising_observer_rolls_back_transactional_command
    # arrange
    observers << ->(event:, command:, result:) { raise ArgumentError, "audit down" }
    command = build_command("Users::Create") { define_method(:call!) { success(user: User.create!(name: "Ana")) } }

    # act
    error = assert_raises(ArgumentError) { command.call }

    # assert
    assert_equal "audit down", error.message
    assert_equal 0, User.count
  end

  def test_raising_observer_propagates_without_undoing_when_transaction_disabled
    # arrange
    observers << ->(event:, command:, result:) { raise ArgumentError, "audit down" }
    command = build_command("Users::Create") do
      transaction :disabled
      define_method(:call!) { success(user: User.create!(name: "Ana")) }
    end

    # act
    error = assert_raises(ArgumentError) { command.call }

    # assert
    assert_equal "audit down", error.message
    assert_equal 1, User.count
  end

  def test_transaction_disabled_notifies_after_success_outside_a_transaction
    # arrange
    collector = observe
    command = build_command("Users::Create") do
      transaction :disabled
      define_method(:call!) { success(user: User.create!(name: "Ana")) }
    end
    baseline = ActiveRecord::Base.connection.open_transactions

    # act
    command.call

    # assert
    call = collector.calls.first
    assert_equal 1, collector.calls.size
    assert call.result.success?
    assert_equal baseline, call.open_transactions
    assert_equal 1, User.count
  end

  def test_emit_notifies_custom_event_before_case_event
    # arrange
    collector = observe
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        success
      end
    end

    # act
    command.call

    # assert
    assert_equal %i[custom case], collector.calls.map { |call| call.event.kind }
    custom = collector.calls.first
    assert_equal "credit_limit_reached", custom.event.name
    assert_equal({ customer_id: 9 }, custom.event.content)
    assert_kind_of command, custom.command
    assert_operator custom.open_transactions, :>, ActiveRecord::Base.connection.open_transactions
  end

  def test_emit_notifies_with_recording_disabled
    # arrange
    with_events(recording: :disabled)
    collector = observe
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end

    # act
    command.call

    # assert
    assert_equal %i[custom case], collector.calls.map { |call| call.event.kind }
  end

  def test_step_event_notifies_observer
    # arrange
    collector = observe
    command = build_command("Order::Place") do
      step(:reserve_stock) { continue(reserved: true) }
      step(:charge_card) { success }
    end
    spy(command, step: :reserve_stock)

    # act
    command.call

    # assert
    step = collector.calls.find { |call| call.event.kind == :step }
    assert_equal "reserve_stock", step.event.step.to_s
    assert_equal "order.place", step.event.name
    assert_kind_of command, step.command
    assert_equal :case, collector.calls.last.event.kind
  end

  def test_query_does_not_notify
    # arrange
    collector = observe
    query = build_case("Dashboard::Evolution", parent: Lucid::Case::Query) { define_method(:call!) { success } }

    # act
    query.call

    # assert
    assert_empty collector.calls
  end

  def test_every_observer_is_notified_in_order
    # arrange
    order = []
    observers << ->(event:, command:, result:) { order << :first }
    observers << ->(event:, command:, result:) { order << :second }

    # act
    approve_command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal %i[first second], order
  end

  def test_no_observers_keeps_current_behavior
    # arrange
    command = approve_command
    spy(command)

    # act
    result = command.call(enrollment: Order.create!(status: "a"))

    # assert
    assert result.success?
    assert_equal 1, events.size
  end
end
