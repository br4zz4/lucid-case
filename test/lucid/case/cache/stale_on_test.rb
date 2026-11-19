require "test_helper"

class StaleOnTest < OutboxTest
  Invalid = Lucid::Case::Error::InvalidSubscription

  def setup
    super
    Lucid::Case.configuration.events.recording = :disabled
    @original_cache_in_use = Lucid::Case.instance_variable_get(:@cache_in_use)
    @store = ActiveSupport::Cache::MemoryStore.new
    config = Lucid::Case.configuration
    config.cache_store = @store
    config.cache_scope = :global
    config.perform_caching = true
  end

  def teardown
    @store.clear
    Lucid::Case.instance_variable_set(:@cache_in_use, @original_cache_in_use)
    super
  end

  def approve(name = "Enrollment::Approve", period: "2026-11", &block)
    build_command(name) do
      attributes :period
      define_method(:call!) { success(period: period) }
      class_eval(&block) if block
    end
  end

  def evolution(name = "Dashboard::Evolution", &block)
    klass = build_case(name, parent: Lucid::Case::Query)
    klass.singleton_class.attr_accessor :calls
    klass.calls = 0
    klass.class_eval do
      cache duration: 5.minutes
      attributes :period
      def call!
        self.class.calls += 1
        success(period: period, run: self.class.calls)
      end
    end
    klass.class_eval(&block) if block
    klass
  end

  def warm(query, period: "2026-11")
    query.call(period: period)
    assert query.call(period: period).cached?
  end

  def hit?(query, period: "2026-11")
    query.call(period: period).cached?
  end

  def test_stale_on_command_invalidates_all_entries_after_success
    # arrange
    command = approve
    query = evolution { stale_on command }
    warm(query, period: "2026-11")
    warm(query, period: "2026-12")

    # act
    command.call(period: "2026-11")

    # assert
    refute hit?(query, period: "2026-11")
    assert hit?(query, period: "2026-11")
    refute hit?(query, period: "2026-12")
  end

  def test_stale_on_is_synchronous_and_in_process
    # arrange
    command = approve
    query = evolution { stale_on command }
    warm(query)

    # act
    command.call(period: "2026-11")

    # assert
    assert_empty enqueued_jobs
    assert_equal 0, record_class.count
    refute hit?(query)
  end

  def test_mapping_invalidates_only_matching_entry
    # arrange
    command = approve
    query = evolution { stale_on command, period: ->(event) { event.content[:period] } }
    warm(query, period: "2026-11")
    warm(query, period: "2026-12")

    # act
    command.call(period: "2026-11")

    # assert
    refute hit?(query, period: "2026-11")
    assert hit?(query, period: "2026-12")
  end

  def test_mapping_lambda_receives_event_with_content_and_input
    # arrange
    command = approve
    received = []
    evolution { stale_on command, period: ->(event) { (received << event) && event.content[:period] } }

    # act
    command.call(period: "2026-11")

    # assert
    assert_equal 1, received.size
    assert_kind_of Lucid::Case::Event, received.first
    assert_equal({ period: "2026-11" }, received.first.content)
    assert_equal "2026-11", received.first.input[:period]
  end

  def test_default_on_is_success_and_failure_does_not_invalidate
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    query = evolution { stale_on command }
    warm(query)

    # act
    command.call

    # assert
    assert hit?(query)
  end

  def test_on_failure_invalidates_after_case_rollback
    # arrange
    command = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    query = evolution { stale_on command, on: :failure }
    warm(query)

    # act
    command.call

    # assert
    refute hit?(query)
  end

  def test_on_any_invalidates_for_success_and_failure
    # arrange
    ok = approve
    bad = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    query = evolution do
      stale_on ok, on: :any
      stale_on bad, on: :any
    end
    warm(query)

    # act
    bad.call
    failure_was_hit = hit?(query)
    warm(query)
    ok.call(period: "2026-11")

    # assert
    refute failure_was_hit
    refute hit?(query)
  end

  def test_on_failure_type_filters
    # arrange
    command = build_command("Payment::Charge") do
      attributes :reason
      define_method(:call!) { failure(reason) }
    end
    query = evolution { stale_on command, on: :card_declined }
    warm(query)

    # act
    command.call(reason: :timeout)
    after_other = hit?(query)
    command.call(reason: :card_declined)

    # assert
    assert after_other
    refute hit?(query)
  end

  def test_on_array_accepts_failure_types
    # arrange
    command = build_command("Payment::Charge") do
      attributes :reason
      define_method(:call!) { failure(reason) }
    end
    query = evolution { stale_on command, on: %i[card_declined timeout] }
    warm(query)

    # act
    command.call(reason: :timeout)

    # assert
    refute hit?(query)
  end

  def test_outer_rollback_does_not_invalidate
    # arrange
    command = approve
    query = evolution { stale_on command }
    warm(query)

    # act
    ActiveRecord::Base.transaction do
      command.call(period: "2026-11")
      raise ActiveRecord::Rollback
    end

    # assert
    assert hit?(query)
  end

  def test_outer_commit_invalidates_after_outer_transaction
    # arrange
    command = approve
    query = evolution { stale_on command }
    warm(query)

    # act
    ActiveRecord::Base.transaction { command.call(period: "2026-11") }

    # assert
    refute hit?(query)
  end

  def test_works_with_recording_disabled_inline_and_outbox
    %i[inline outbox].each do |store|
      # arrange
      with_events(store: store, recording: :disabled)
      command = approve("Enrollment::Approve")
      query = evolution { stale_on command }
      warm(query)

      # act
      command.call(period: "2026-11")

      # assert
      refute hit?(query), "store #{store}"
      assert_equal 0, record_class.count
      assert_empty enqueued_jobs
      Lucid::Case::Events::Registry.clear!
    end
  end

  def test_recording_enabled_records_event_besides_invalidating
    # arrange
    with_events(store: :outbox, recording: :enabled)
    command = approve
    query = evolution { stale_on command }
    warm(query)

    # act
    command.call(period: "2026-11")

    # assert
    refute hit?(query)
    assert_equal 1, record_class.count
  end

  def test_step_stale_on_invalidates_when_step_finishes
    # arrange
    place = build_command("Order::Place") do
      step(:reserve_stock) { continue(reserved: true) }
      step(:charge_card) { success }
    end
    query = evolution { stale_on place, step: :reserve_stock }
    warm(query)

    # act
    place.call

    # assert
    refute hit?(query)
  end

  def test_step_stale_on_does_not_invalidate_when_later_step_fails_transactionally
    # arrange
    place = build_command("Order::Place") do
      step(:reserve_stock) { continue }
      step(:charge_card) { failure(:card_declined) }
    end
    query = evolution { stale_on place, step: :reserve_stock }
    warm(query)

    # act
    place.call

    # assert
    assert hit?(query)
  end

  def test_custom_event_invalidates_after_commit
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end
    query = evolution { stale_on :credit_limit_reached }
    warm(query)

    # act
    command.call

    # assert
    refute hit?(query)
    assert_equal 0, record_class.count
  end

  def test_custom_event_by_string_name
    # arrange
    command = build_command("Payment::Charge") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end
    query = evolution { stale_on "credit_limit_reached" }
    warm(query)

    # act
    command.call

    # assert
    refute hit?(query)
  end

  def test_custom_event_with_on_raises
    # arrange
    query = nil

    # act
    error = assert_raises(Invalid) { query = evolution { stale_on :credit_limit_reached, on: :failure } }

    # assert
    assert_nil query
    assert_kind_of Lucid::Case::Error, error
  end

  def test_stale_on_does_not_interfere_with_subscribers
    # arrange
    with_events(store: :outbox, recording: :enabled)
    command = approve
    build_subscriber("Billing::OnApproved") do
      subscribe command
      define_method(:call!) { success }
    end
    query = evolution { stale_on command }
    warm(query)

    # act
    command.call(period: "2026-11")

    # assert
    refute hit?(query)
    assert_equal 1, delivery_arguments.size
    assert_equal 1, enqueued_jobs.size
  end

  def test_stale_on_in_command_raises_at_load
    # arrange
    target = approve("Enrollment::Reject")

    # act
    # assert
    assert_raises(Invalid) { build_command("Enrollment::Other") { stale_on target } }
  end

  def test_stale_on_in_subscriber_raises_at_load
    # arrange
    target = approve

    # act
    # assert
    assert_raises(Invalid) do
      build_subscriber("Billing::OnApproved") do
        subscribe target
        stale_on target
      end
    end
  end

  def test_query_target_raises
    # arrange
    other = evolution("Dashboard::Other")

    # act
    # assert
    assert_raises(Invalid) { evolution { stale_on other } }
  end

  def test_subscriber_target_raises
    # arrange
    command = approve
    subscriber = build_subscriber("Billing::OnApproved") do
      subscribe command
      define_method(:call!) { success }
    end

    # act
    # assert
    assert_raises(Invalid) { evolution { stale_on subscriber } }
  end

  def test_unknown_step_raises
    # arrange
    place = build_command("Order::Place") { step(:reserve_stock) { continue } }

    # act
    # assert
    assert_raises(Invalid) { evolution { stale_on place, step: :missing } }
  end

  def test_registry_clear_removes_stale_on_subscriptions
    # arrange
    command = approve
    query = evolution { stale_on command }
    warm(query)

    # act
    Lucid::Case::Events::Registry.clear!
    command.call(period: "2026-11")

    # assert
    assert hit?(query)
  end
end
