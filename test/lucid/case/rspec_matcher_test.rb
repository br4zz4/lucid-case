require "test_helper"
require "rspec/expectations"
require "lucid/case/rspec"

class RSpecMatcherTest < OutboxTest
  include RSpec::Matchers
  include Lucid::Case::RSpecMatchers

  def setup
    super
    hold_events
  end

  def test_emit_event_with_type_and_content_passes
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    matcher = emit_event(command).with(type: :ok, content: { enrollment: order })

    # assert
    expect { command.call(enrollment: order) }.to matcher
  end

  def test_not_to_emit_event_passes_when_nothing_is_emitted
    # arrange
    command = approve_command

    # act
    matcher = emit_event(command)

    # assert
    expect { }.not_to matcher
  end

  def test_matcher_fails_with_useful_message_when_type_differs
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    error = assert_raises(RSpec::Expectations::ExpectationNotMetError) do
      expect { command.call(enrollment: order) }.to emit_event(command).with(type: :card_declined)
    end

    # assert
    assert_includes error.message, "enrollment.approve"
  end

  def test_negated_matcher_fails_when_event_is_emitted
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    error = assert_raises(RSpec::Expectations::ExpectationNotMetError) do
      expect { command.call(enrollment: order) }.not_to emit_event(command)
    end

    # assert
    assert_includes error.message, "enrollment.approve"
  end

  def test_matches_custom_event_by_symbol
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached, customer_id: 9)
        success
      end
    end

    # act
    matcher = emit_event(:credit_limit_reached).with(content: { customer_id: 9 })

    # assert
    expect { command.call }.to matcher
  end

  def test_matches_step_event
    # arrange
    command = build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end

    # act
    matcher = emit_event(command).with(step: :reserve_stock)

    # assert
    expect { command.call }.to matcher
  end

  def test_matches_input_subset
    # arrange
    command = build_command("Users::Create") do
      attributes :flag
      define_method(:call!) { success }
    end

    # act
    matcher = emit_event(command).with(input: { flag: true })

    # assert
    expect { command.call(flag: true) }.to matcher
  end

  def test_matcher_is_dry
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")

    # act
    expect { command.call(enrollment: order) }.to emit_event(command)

    # assert
    assert_equal 0, record_class.count
    assert_empty enqueued_jobs
  end

  def test_matcher_contract
    # arrange
    matcher = emit_event(approve_command)

    # act
    description = matcher.description

    # assert
    assert matcher.supports_block_expectations?
    assert_kind_of String, description
    assert_includes description, "emit"
  end

  def test_matcher_methods_report_results
    # arrange
    command = approve_command
    order = Order.create!(status: "pending")
    matcher = emit_event(command)

    # act
    matched = matcher.matches?(-> { command.call(enrollment: order) })
    message = matcher.failure_message_when_negated
    unmatched = emit_event(command)
    refused = unmatched.does_not_match?(-> { })

    # assert
    assert matched
    assert_kind_of String, message
    assert refused
  end

  def test_failure_message_is_a_string
    # arrange
    command = approve_command
    matcher = emit_event(command)

    # act
    matched = matcher.matches?(-> { })

    # assert
    refute matched
    assert_kind_of String, matcher.failure_message
  end
end
