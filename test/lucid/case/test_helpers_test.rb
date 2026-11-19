require "test_helper"
require "lucid/case/test_helpers"

class TestHelpersTest < OutboxTest
  include Lucid::Case::TestHelpers

  def setup
    super
    hold_events
  end

  def charge_command(result: :ok)
    build_command("Payment::Charge") do
      attributes :payment
      define_method(:call!) do
        result == :ok ? success(payment: payment) : failure(:card_declined, payment: payment)
      end
    end
  end

  def emitting_command
    build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        success
      end
    end
  end

  def stepped_command
    build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end
  end

  def test_capture_events_returns_case_event_on_success
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    captured = capture_events { command.call(enrollment: order) }

    # assert
    assert_equal 1, captured.size
    assert_kind_of Lucid::Case::Event, captured.first
    assert_equal "enrollment.approve", captured.first.name
    assert_equal :ok, captured.first.type
    assert_equal order, captured.first.content[:enrollment]
  end

  def test_capture_events_returns_case_event_on_failure
    # arrange
    command = charge_command(result: :failure)
    payment = Order.create!(status: "pending")

    # act
    captured = capture_events { command.call(payment: payment) }

    # assert
    assert_equal 1, captured.size
    assert_equal :card_declined, captured.first.type
  end

  def test_capture_events_includes_custom_events_in_recording_order
    # arrange
    command = emitting_command

    # act
    captured = capture_events { command.call }

    # assert
    custom = captured.find { |event| event.kind == :custom }
    assert_equal ["credit_limit_reached", "payment.charge"], captured.map(&:name).sort
    assert_equal({ customer_id: 9 }, custom.content)
  end

  def test_capture_events_includes_step_events_without_subscribers
    # arrange
    command = stepped_command

    # act
    captured = capture_events { command.call }

    # assert
    assert_includes captured.map(&:kind), :step
    assert_includes captured.map(&:kind), :case
  end

  def test_capture_events_works_with_recording_disabled
    # arrange
    with_events(store: :outbox, recording: :disabled)
    command = approve_command

    # act
    captured = capture_events { command.call(enrollment: Order.create!(status: "pending")) }

    # assert
    assert_equal ["enrollment.approve"], captured.map(&:name)
  end

  def test_capture_events_respects_command_with_events_disabled
    # arrange
    command = build_command("Enrollment::Approve") do
      events :disabled
      define_method(:call!) { success }
    end

    # act
    captured = capture_events { command.call }

    # assert
    assert_empty captured
  end

  def test_capture_events_is_dry_with_outbox_store
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    capture_events { command.call(enrollment: order) }

    # assert
    assert_equal 0, record_class.count
    assert_empty enqueued_jobs
  end

  def test_capture_events_is_dry_with_inline_store
    # arrange
    with_events(store: :inline)
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    capture_events { command.call(enrollment: order) }

    # assert
    assert_equal 0, record_class.count
    assert_empty enqueued_jobs
  end

  def test_capture_events_does_not_require_the_table
    # arrange
    Lucid::Case.configuration.events.table_name = "missing_events_table"
    command = approve_command

    # act
    captured = capture_events { command.call(enrollment: Order.create!(status: "pending")) }

    # assert
    assert_equal 1, captured.size
  end

  def test_capture_events_does_not_call_subscribers
    # arrange
    approve = approve_command
    spy(approve)

    # act
    capture_events { approve.call(enrollment: Order.create!(status: "pending")) }

    # assert
    assert_empty events
  end

  def test_capture_events_works_inside_an_outer_transaction
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    captured = ActiveRecord::Base.transaction do
      capture_events { command.call(enrollment: order) }
    end

    # assert
    assert_equal 1, captured.size
    assert_equal 0, record_class.count
  end

  def test_capture_events_returns_events_even_when_the_command_fails
    # arrange
    command = charge_command(result: :failure)

    # act
    captured = capture_events { command.call(payment: Order.create!(status: "pending")) }

    # assert
    assert_equal [:card_declined], captured.map(&:type)
  end

  def test_nested_captures_see_only_their_scope
    # arrange
    approve = approve_command
    reject = build_command("Enrollment::Reject") { define_method(:call!) { failure(:rejected) } }
    order = Order.create!(status: "pending")
    inner = nil

    # act
    outer = capture_events do
      approve.call(enrollment: order)
      inner = capture_events { reject.call }
    end

    # assert
    assert_equal ["enrollment.reject"], inner.map(&:name)
    assert_equal ["enrollment.approve", "enrollment.reject"], outer.map(&:name)
  end

  def test_capture_is_closed_when_the_block_raises
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    assert_raises(RuntimeError) { capture_events { raise "boom" } }
    command.call(enrollment: order)

    # assert
    assert_equal 1, record_class.count
    assert_equal [], capture_events { }
  end

  def test_assert_event_passes_for_a_case_event
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    event = assert_event(command) { command.call(enrollment: order) }

    # assert
    assert_kind_of Lucid::Case::Event, event
    assert_equal "enrollment.approve", event.name
  end

  def test_assert_event_matches_type_and_content_subset
    # arrange
    command = charge_command(result: :failure)
    payment = Order.create!(status: "pending")

    # act
    event = assert_event(command, type: :card_declined, content: { payment: payment }) do
      command.call(payment: payment)
    end

    # assert
    assert_equal :card_declined, event.type
  end

  def test_assert_event_matches_input_subset
    # arrange
    command = build_command("Users::Create") do
      attributes :params, :flag
      define_method(:call!) { success }
    end

    # act
    event = assert_event(command, input: { flag: true }) { command.call(params: { a: 1 }, flag: true) }

    # assert
    assert_equal true, event.input[:flag]
  end

  def test_assert_event_fails_when_type_differs_and_lists_captured_events
    # arrange
    command = charge_command(result: :failure)
    payment = Order.create!(status: "pending")

    # act
    error = assert_raises(Minitest::Assertion) do
      assert_event(command, type: :ok) { command.call(payment: payment) }
    end

    # assert
    assert_includes error.message, "payment.charge"
  end

  def test_assert_event_fails_when_nothing_was_emitted
    # arrange
    command = approve_command

    # act
    error = assert_raises(Minitest::Assertion) { assert_event(command) { } }

    # assert
    assert_kind_of Minitest::Assertion, error
  end

  def test_assert_event_fails_when_content_differs
    # arrange
    command = charge_command
    payment = Order.create!(status: "pending")
    other = Order.create!(status: "other")

    # act
    assert_raises(Minitest::Assertion) do
      assert_event(command, content: { payment: other }) { command.call(payment: payment) }
    end
  end

  def test_assert_event_matches_custom_event_by_symbol_and_string
    # arrange
    command = emitting_command

    # act
    by_symbol = assert_event(:credit_limit_reached, content: { customer_id: 9 }) { command.call }
    by_string = assert_event("credit_limit_reached") { command.call }

    # assert
    assert_equal :custom, by_symbol.kind
    assert_equal :custom, by_string.kind
  end

  def test_assert_event_matches_step_event
    # arrange
    command = stepped_command

    # act
    event = assert_event(command, step: :reserve_stock) { command.call }

    # assert
    assert_equal :step, event.kind
  end

  def test_assert_event_fails_for_command_with_events_disabled
    # arrange
    command = build_command("Enrollment::Approve") do
      events :disabled
      define_method(:call!) { success }
    end

    # act
    assert_raises(Minitest::Assertion) { assert_event(command) { command.call } }
  end

  def test_assert_no_event_passes_when_nothing_matches
    # arrange
    command = approve_command

    # act
    assert_no_event(command) { }
  end

  def test_assert_no_event_passes_for_a_different_type
    # arrange
    command = charge_command(result: :failure)
    payment = Order.create!(status: "pending")

    # act
    assert_no_event(command, type: :ok) { command.call(payment: payment) }
  end

  def test_assert_no_event_fails_citing_the_found_event
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    error = assert_raises(Minitest::Assertion) do
      assert_no_event(command) { command.call(enrollment: order) }
    end

    # assert
    assert_includes error.message, "enrollment.approve"
  end

  def test_assert_event_is_dry
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    assert_event(command) { command.call(enrollment: order) }

    # assert
    assert_equal 0, record_class.count
    assert_empty enqueued_jobs
  end

  def test_require_lucid_case_alone_does_not_define_test_helpers
    # arrange
    script = 'require "lucid/case"; exit(defined?(Lucid::Case::TestHelpers) ? 1 : 0)'
    lib = File.expand_path("../../../lib", __dir__)

    # act
    result = system(RbConfig.ruby, "-I", lib, "-e", script, out: File::NULL, err: File::NULL)

    # assert
    assert result
  end
end
