require "test_helper"

class SubscriberTest < Minitest::Test
  Error = Lucid::Case::Error

  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
    Lucid::Case::Events::Registry.clear! if defined?(Lucid::Case::Events::Registry)
    User.delete_all
  end

  def teardown
    Lucid::Case::Events::Registry.clear! if defined?(Lucid::Case::Events::Registry)
    Lucid::Case.instance_variable_set(:@configuration, @original)
    User.delete_all
  end

  def build_command(name = "Enrollment::Approve", &block)
    build_case(name, parent: Lucid::Case::Command) do
      def call! = success
      class_eval(&block) if block
    end
  end

  def build_event(**overrides)
    Lucid::Case::Event.new(
      **{ id: "e1", kind: :case, name: "enrollment.approve", source: "Enrollment::Approve", type: :ok, occurred_at: Time.now }.merge(overrides)
    )
  end

  def test_kinds_include_subscriber
    # assert
    assert_equal %i[command query subscriber], Lucid::Case::Kinds::KINDS
  end

  def test_subscriber_kind
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber)

    # assert
    assert_equal :subscriber, klass.kind
    assert klass.subscriber?
    refute klass.command?
    refute klass.query?
  end

  def test_command_and_query_are_not_subscribers
    # assert
    refute build_case(parent: Lucid::Case::Command).subscriber?
    refute build_case(parent: Lucid::Case::Query).subscriber?
  end

  def test_subscriber_is_a_case
    # assert
    assert_operator Lucid::Case::Subscriber, :<, Lucid::Case
  end

  def test_subscriber_cannot_change_kind
    # act / assert
    assert_raises(Error::InvalidKind) { build_case(parent: Lucid::Case::Subscriber) { kind :command } }
  end

  def test_subscriber_declares_event_attribute
    # arrange
    seen = nil
    klass = build_case(parent: Lucid::Case::Subscriber) do
      define_method(:call!) do
        seen = event
        success
      end
    end
    event = build_event

    # act
    result = klass.call(event: event)

    # assert
    assert_kind_of Lucid::Case::Result, result
    assert result.success?
    assert_same event, seen
  end

  def test_subscriber_is_transactional_by_default
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber)

    # assert
    assert klass.transactional?
  end

  def test_subscriber_rolls_back_on_failure
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber) do
      def call!
        User.create!(name: "Ana")
        failure(:nope)
      end
    end

    # act
    result = klass.call(event: build_event)

    # assert
    assert result.failure?
    assert_equal 0, User.count
  end

  def test_subscriber_commits_on_success
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber) do
      def call! = success(user: User.create!(name: "Ana"))
    end

    # act
    klass.call(event: build_event)

    # assert
    assert_equal 1, User.count
  end

  def test_subscriber_transaction_disabled_is_accepted
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber) do
      transaction :disabled
      def call!
        User.create!(name: "Ana")
        failure(:nope)
      end
    end

    # act
    result = klass.call(event: build_event)

    # assert
    refute klass.transactional?
    assert result.failure?
    assert_equal 1, User.count
  end

  def test_subscriber_accepts_steps
    # arrange
    klass = build_case(parent: Lucid::Case::Subscriber) do
      step(:one) { continue(a: 1) }
      step(:two) { success(b: 2) }
    end

    # act
    result = klass.call(event: build_event)

    # assert
    assert result.success?
    assert_equal 2, result.content[:b]
  end

  def test_subscriber_accepts_catch_and_finally
    # arrange
    log = []
    klass = build_case(parent: Lucid::Case::Subscriber) do
      catch(RuntimeError) { failure(:boom) }
      finally { log << :finally }
      def call! = raise("x")
    end

    # act
    result = klass.call(event: build_event)

    # assert
    assert_equal :boom, result.type
    assert_equal [:finally], log
  end

  def test_subscriber_accepts_hooks
    # arrange
    log = []
    klass = build_case(parent: Lucid::Case::Subscriber) do
      after_success { log << :after_success }
      def call! = success
    end

    # act
    klass.call(event: build_event)

    # assert
    assert_equal [:after_success], log
  end

  def test_subscribe_in_command_raises
    # arrange
    target = build_command

    # act / assert
    assert_raises(Error::SubscribeOutsideSubscriber) do
      build_case(parent: Lucid::Case::Command) { subscribe target }
    end
  end

  def test_subscribe_in_query_raises
    # arrange
    target = build_command

    # act / assert
    assert_raises(Error::SubscribeOutsideSubscriber) do
      build_case(parent: Lucid::Case::Query) { subscribe target }
    end
  end

  def test_subscribe_in_plain_case_raises
    # arrange
    target = build_command

    # act / assert
    assert_raises(Error::SubscribeOutsideSubscriber) do
      build_case { kind :command; subscribe target }
    end
  end

  def test_subscribe_in_command_does_not_register
    # arrange
    target = build_command

    # act
    begin
      build_case(parent: Lucid::Case::Command) { subscribe target }
    rescue Error::SubscribeOutsideSubscriber
      nil
    end

    # assert
    assert_equal [], Lucid::Case::Events::Registry.subscriptions
  end

  def test_errors_hierarchy
    # assert
    %i[SubscribeOutsideSubscriber InvalidSubscription EmitOutsideCommand UnserializableEvent RelayFailed].each do |name|
      assert_operator Error.const_get(name), :<, Error, name.to_s
    end
  end

  def test_subscribe_query_target_is_invalid
    # arrange
    query = build_case("Dashboard::Evolution", parent: Lucid::Case::Query)

    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe query }
    end
  end

  def test_subscribe_subscriber_target_is_invalid
    # arrange
    other = build_case("Billing::Other", parent: Lucid::Case::Subscriber)

    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe other }
    end
  end

  def test_subscribe_unknown_step_is_invalid
    # arrange
    target = build_case("Order::Place", parent: Lucid::Case::Command) do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end

    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe target, step: :missing }
    end
  end

  def test_subscribe_known_step_is_valid
    # arrange
    target = build_case("Order::Place", parent: Lucid::Case::Command) do
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end

    # act
    build_case(parent: Lucid::Case::Subscriber) { subscribe target, step: :reserve_stock }

    # assert
    assert_equal 1, Lucid::Case::Events::Registry.subscriptions.size
  end

  def test_on_in_custom_event_is_invalid
    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe :credit_limit_reached, on: :failure }
    end
  end

  def test_on_with_non_symbol_value_is_invalid
    # arrange
    target = build_command

    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe target, on: 1 }
    end
  end

  def test_on_array_with_non_symbol_is_invalid
    # arrange
    target = build_command

    # act / assert
    assert_raises(Error::InvalidSubscription) do
      build_case(parent: Lucid::Case::Subscriber) { subscribe target, on: [:success, 1] }
    end
  end

  def test_invalid_subscription_does_not_register
    # arrange
    target = build_command

    # act
    begin
      build_case(parent: Lucid::Case::Subscriber) { subscribe target, on: 1 }
    rescue Error::InvalidSubscription
      nil
    end

    # assert
    assert_equal [], Lucid::Case::Events::Registry.subscriptions
  end
end
