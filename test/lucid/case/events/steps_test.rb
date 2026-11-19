require "test_helper"

class EventsStepsTest < EventsTest
  def order_place(&block)
    build_command("Order::Place") do
      step(:reserve_stock) { continue(reserved: true) }
      step(:charge_card) { success(charged: true) }
      class_eval(&block) if block
    end
  end

  def test_subscribed_step_records_step_event
    # arrange
    target = order_place
    spy(target, step: :reserve_stock)

    # act
    target.call

    # assert
    event = events.first
    assert_equal 1, events.size
    assert_equal :step, event.kind
    assert_equal "order.place", event.name
    assert_equal :reserve_stock, event.step
    assert_equal :ok, event.type
    assert_equal({ reserved: true }, event.content)
    assert_equal "Order::Place", event.source
  end

  def test_step_subscription_does_not_receive_case_event
    # arrange
    target = order_place
    spy(target, step: :reserve_stock)

    # act
    target.call

    # assert
    assert_equal [:step], events.map(&:kind)
  end

  def test_skip_to_step_event_carries_content
    # arrange
    target = build_command("Order::Place") do
      step(:reserve_stock) { skip_to(:charge_card, skipped: true) }
      step(:unused) { failure(:never) }
      step(:charge_card) { success }
    end
    spy(target, step: :reserve_stock)

    # act
    target.call

    # assert
    assert_equal({ skipped: true }, events.first.content)
  end

  def test_success_step_records_step_event
    # arrange
    target = order_place
    spy(target, step: :charge_card, as: :step_spy)

    # act
    target.call

    # assert
    assert_equal({ charged: true }, events.first.content)
  end

  def test_transactional_case_failing_later_delivers_no_step_event
    # arrange
    target = build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { failure(:card_declined) }
    end
    spy(target, step: :reserve_stock)

    # act
    target.call

    # assert
    assert_empty events
  end

  def test_transactional_case_raising_later_delivers_no_step_event
    # arrange
    target = build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { raise "boom" }
    end
    spy(target, step: :reserve_stock)

    # act / assert
    assert_raises(RuntimeError) { target.call }
    assert_empty events
  end

  def test_non_transactional_case_delivers_step_event_even_if_next_step_raises
    # arrange
    target = build_command("Provisioning::Run") do
      transaction :disabled
      step(:start) { continue }
      step(:configure_dns) { raise "dns down" }
    end
    spy(target, step: :start)

    # act / assert
    assert_raises(RuntimeError) { target.call }
    assert_equal 1, events.size
    assert_equal :start, events.first.step
    assert_equal :step, events.first.kind
  end

  def test_step_without_subscription_records_nothing_observable
    # arrange
    target = order_place
    spy(target, step: :charge_card)

    # act
    result = target.call

    # assert
    assert result.success?
    assert_equal [:charge_card], events.map(&:step)
  end

  def test_step_event_waits_for_outer_commit
    # arrange
    target = order_place
    spy(target, step: :reserve_stock)
    inside = nil

    # act
    ActiveRecord::Base.transaction do
      target.call
      inside = events.dup
    end

    # assert
    assert_empty inside
    assert_equal 1, events.size
  end

  def test_step_subscriber_class_receives_step_event
    # arrange
    target = order_place
    received = []
    build_subscriber("Stock::OnReserved") do
      subscribe target, step: :reserve_stock
      define_method(:call!) do
        received << event
        success
      end
    end

    # act
    target.call

    # assert
    assert_equal [:reserve_stock], received.map(&:step)
  end
end
