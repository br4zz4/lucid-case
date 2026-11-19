require "test_helper"

class EventsRegistryTest < Minitest::Test
  def registry = Lucid::Case::Events::Registry

  def subscription_class = Lucid::Case::Events::Subscription

  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
    registry.clear!
  end

  def teardown
    registry.clear!
    Lucid::Case.instance_variable_set(:@configuration, @original)
  end

  def build_command(name)
    build_case(name, parent: Lucid::Case::Command) { def call! = success }
  end

  def build_subscriber(name = "Billing::OnEvent", &block)
    build_case(name, parent: Lucid::Case::Subscriber, &block)
  end

  def match(**overrides)
    registry.matching(**{ kind: :case, name: "enrollment.approve", step: nil, type: :ok, success: true }.merge(overrides))
  end

  def test_starts_empty_after_clear
    # assert
    assert_equal [], registry.subscriptions
  end

  def test_subscribe_registers_a_subscription
    # arrange
    target = build_command("Enrollment::Approve")
    subscriber = build_subscriber("Billing::OnApproved") { subscribe target }

    # act
    subscriptions = registry.subscriptions

    # assert
    assert_equal 1, subscriptions.size
    subscription = subscriptions.first
    assert_kind_of subscription_class, subscription
    assert_equal "enrollment.approve", subscription.target_name
    assert_equal :case, subscription.kind
    assert_nil subscription.step
    assert_equal :success, subscription.on
    assert_equal false, subscription.ordered
    assert_equal "Billing::OnApproved", subscription.subscriber_id
    assert_same subscriber, subscription.handler
  end

  def test_event_name_from_namespaced_class
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target }

    # assert
    assert_equal "enrollment.approve", registry.subscriptions.first.target_name
  end

  def test_custom_event_symbol_and_string_share_the_name
    # arrange
    build_subscriber("A") { subscribe :credit_limit_reached }
    build_subscriber("B") { subscribe "credit_limit_reached" }

    # act
    subscriptions = registry.subscriptions

    # assert
    assert_equal ["credit_limit_reached"] * 2, subscriptions.map(&:target_name)
    assert_equal [:custom, :custom], subscriptions.map(&:kind)
    assert_equal 2, match(kind: :custom, name: "credit_limit_reached", type: nil).size
  end

  def test_step_subscription
    # arrange
    target = build_case("Order::Place", parent: Lucid::Case::Command) do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end
    build_subscriber { subscribe target, step: :reserve_stock }

    # act
    subscription = registry.subscriptions.first

    # assert
    assert_equal :step, subscription.kind
    assert_equal :reserve_stock, subscription.step
    assert_equal 1, match(kind: :step, name: "order.place", step: :reserve_stock).size
    assert_equal 0, match(kind: :step, name: "order.place", step: :charge_card).size
    assert_equal 0, match(kind: :case, name: "order.place").size
  end

  def test_matching_default_on_success
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target }

    # assert
    assert_equal 1, match.size
    assert_equal 0, match(success: false, type: :card_declined).size
  end

  def test_matching_on_failure
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target, on: :failure }

    # assert
    assert_equal 1, match(success: false, type: :card_declined).size
    assert_equal 0, match.size
  end

  def test_matching_on_any
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target, on: :any }

    # assert
    assert_equal 1, match.size
    assert_equal 1, match(success: false, type: :card_declined).size
  end

  def test_matching_on_failure_type
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target, on: :card_declined }

    # assert
    assert_equal 1, match(success: false, type: :card_declined).size
    assert_equal 0, match(success: false, type: :expired).size
    assert_equal 0, match.size
  end

  def test_matching_on_array
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target, on: [:success, :card_declined] }

    # assert
    assert_equal 1, match.size
    assert_equal 1, match(success: false, type: :card_declined).size
    assert_equal 0, match(success: false, type: :expired).size
  end

  def test_matching_ignores_other_names_and_kinds
    # arrange
    target = build_command("Enrollment::Approve")
    build_subscriber { subscribe target }

    # assert
    assert_equal 0, match(name: "enrollment.reject").size
    assert_equal 0, match(kind: :custom).size
  end

  def test_custom_event_does_not_collide_with_case_event
    # arrange
    build_subscriber { subscribe "enrollment.approve" }

    # assert
    assert_equal 1, match(kind: :custom, name: "enrollment.approve", type: nil).size
    assert_equal 0, match(kind: :case, name: "enrollment.approve").size
  end

  def test_multiple_subscriptions_in_one_subscriber
    # arrange
    approve = build_command("Enrollment::Approve")
    reject = build_command("Enrollment::Reject")
    build_subscriber("Billing::Multi") do
      subscribe approve
      subscribe reject, on: :any
      subscribe :credit_limit_reached
    end

    # act
    subscriptions = registry.subscriptions

    # assert
    assert_equal 3, subscriptions.size
    assert_equal ["Billing::Multi"], subscriptions.map(&:subscriber_id).uniq
  end

  def test_external_subscribe_call
    # arrange
    target = build_command("Enrollment::Approve")
    subscriber = build_subscriber("Billing::External")

    # act
    subscriber.subscribe(target)

    # assert
    assert_equal 1, match.size
    assert_same subscriber, match.first.handler
  end

  def test_global_block_subscription
    # arrange
    target = build_command("Enrollment::Approve")
    block = proc { |event| event }

    # act
    Lucid::Case.subscribe(target, as: :guardian_mailer, &block)

    # assert
    subscription = match.first
    assert_equal "guardian_mailer", subscription.subscriber_id
    assert_same block, subscription.handler
  end

  def test_global_block_accepts_string_as_and_options
    # arrange
    target = build_command("Enrollment::Approve")

    # act
    Lucid::Case.subscribe(target, as: "mailer", on: :any) { |_event| nil }

    # assert
    assert_equal "mailer", registry.subscriptions.first.subscriber_id
    assert_equal :any, registry.subscriptions.first.on
  end

  def test_global_block_without_as_is_allowed_by_default
    # arrange
    target = build_command("Enrollment::Approve")

    # act
    Lucid::Case.subscribe(target) { |_event| nil }

    # assert
    assert_equal 1, registry.subscriptions.size
  end

  def test_global_subscribe_requires_a_block
    # arrange
    target = build_command("Enrollment::Approve")

    # act / assert
    assert_raises(ArgumentError) { Lucid::Case.subscribe(target) }
  end

  def test_global_block_without_as_with_deduplication_raises
    # arrange
    target = build_command("Enrollment::Approve")
    Lucid::Case.configure { |config| config.events.deduplication = :enabled }

    # act / assert
    assert_raises(Lucid::Case::Error::InvalidSubscription) { Lucid::Case.subscribe(target) { |_e| nil } }
    assert_equal [], registry.subscriptions
  end

  def test_global_block_with_as_and_deduplication_is_valid
    # arrange
    target = build_command("Enrollment::Approve")
    Lucid::Case.configure { |config| config.events.deduplication = :enabled }

    # act
    Lucid::Case.subscribe(target, as: :mailer) { |_e| nil }

    # assert
    assert_equal 1, registry.subscriptions.size
  end

  def test_global_block_ordered_without_as_raises
    # arrange
    target = build_command("Enrollment::Approve")

    # act / assert
    assert_raises(Lucid::Case::Error::InvalidSubscription) { Lucid::Case.subscribe(target, ordered: true) { |_e| nil } }
  end

  def test_global_block_ordered_with_as
    # arrange
    target = build_command("Enrollment::Approve")

    # act
    Lucid::Case.subscribe(target, as: :ledger, ordered: true) { |_e| nil }

    # assert
    assert_equal true, registry.subscriptions.first.ordered
  end

  def test_ordered_subscription_in_subscriber
    # arrange
    target = build_command("Ledger::Post")
    build_subscriber { subscribe target, ordered: true }

    # assert
    assert_equal true, registry.subscriptions.first.ordered
  end

  def test_register_and_matching_with_manual_subscription
    # arrange
    handler = proc { |_e| nil }
    subscription = subscription_class.new(
      target_name: "x", kind: :custom, step: nil, on: :success, ordered: false, subscriber_id: "manual", handler: handler
    )

    # act
    registry.register(subscription)

    # assert
    assert_equal [subscription], registry.subscriptions
    assert_equal [subscription], match(kind: :custom, name: "x", type: nil)
  end

  def test_clear_removes_everything
    # arrange
    build_subscriber { subscribe :x }

    # act
    registry.clear!

    # assert
    assert_equal [], registry.subscriptions
  end

  def test_thread_safe_registration
    # arrange
    handler = proc { |_e| nil }

    # act
    10.times.map do |t|
      Thread.new do
        5.times do |i|
          registry.register(
            subscription_class.new(target_name: "t#{t}_#{i}", kind: :custom, step: nil, on: :success, ordered: false, subscriber_id: "s#{t}_#{i}", handler: handler)
          )
        end
      end
    end.each(&:join)

    # assert
    assert_equal 50, registry.subscriptions.size
  end
end
