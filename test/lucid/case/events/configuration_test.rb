require "test_helper"

class EventsConfigurationTest < Minitest::Test
  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
  end

  def teardown
    Lucid::Case.instance_variable_set(:@configuration, @original)
  end

  def test_events_is_a_configuration_object
    # act
    events = Lucid::Case.configuration.events

    # assert
    assert_kind_of Lucid::Case::Events::Configuration, events
  end

  def test_defaults
    # arrange
    events = Lucid::Case.configuration.events

    # act
    values = [
      events.recording, events.store, events.transport, events.queue, events.delivery_attempts,
      events.table_name, events.deliveries_table_name, events.cursors_table_name,
      events.retention, events.purge, events.claim_timeout, events.deduplication
    ]

    # assert
    assert_equal [
      :disabled, :outbox, :active_job, :default, 5,
      "lucid_case_events", "lucid_case_deliveries", "lucid_case_cursors",
      7.days, :enabled, 5.minutes, :disabled
    ], values
    assert_equal %w[app/models], events.load_paths
    assert_nil events.context
    assert_nil events.around_delivery
  end

  def test_setters
    # arrange
    events = Lucid::Case.configuration.events
    transport = Object.new
    context = -> { { tenant: 1 } }
    around = ->(ctx, &block) { block.call }

    # act
    events.recording = :enabled
    events.store = :inline
    events.transport = transport
    events.queue = :events
    events.delivery_attempts = 3
    events.table_name = "public.lucid_case_events"
    events.deliveries_table_name = "d"
    events.cursors_table_name = "c"
    events.retention = 1.day
    events.purge = :disabled
    events.claim_timeout = 1.minute
    events.load_paths = %w[app/subscribers]
    events.context = context
    events.around_delivery = around

    # assert
    assert_equal :enabled, events.recording
    assert_equal :inline, events.store
    assert_same transport, events.transport
    assert_equal :events, events.queue
    assert_equal 3, events.delivery_attempts
    assert_equal "public.lucid_case_events", events.table_name
    assert_equal "d", events.deliveries_table_name
    assert_equal "c", events.cursors_table_name
    assert_equal 1.day, events.retention
    assert_equal :disabled, events.purge
    assert_equal 1.minute, events.claim_timeout
    assert_equal %w[app/subscribers], events.load_paths
    assert_same context, events.context
    assert_same around, events.around_delivery
  end

  def test_invalid_recording_raises
    # arrange
    events = Lucid::Case.configuration.events

    # act
    error = assert_raises(ArgumentError) { events.recording = :maybe }

    # assert
    assert_includes error.message, "recording"
    assert_equal :disabled, events.recording
  end

  def test_invalid_purge_raises
    # arrange
    events = Lucid::Case.configuration.events

    # act / assert
    assert_raises(ArgumentError) { events.purge = true }
    assert_equal :enabled, events.purge
  end

  def test_invalid_deduplication_raises
    # arrange
    events = Lucid::Case.configuration.events

    # act / assert
    assert_raises(ArgumentError) { events.deduplication = :maybe }
    assert_equal :disabled, events.deduplication
  end

  def test_invalid_store_raises
    # arrange
    events = Lucid::Case.configuration.events

    # act
    error = assert_raises(ArgumentError) { events.store = :redis }

    # assert
    assert_includes error.message, "store"
    assert_equal :outbox, events.store
  end

  def test_valid_values_are_accepted
    # arrange
    events = Lucid::Case.configuration.events

    # act
    events.recording = :enabled
    events.purge = :disabled
    events.deduplication = :enabled
    events.store = :outbox

    # assert
    assert_equal :enabled, events.recording
    assert_equal :disabled, events.purge
    assert_equal :enabled, events.deduplication
    assert_equal :outbox, events.store
  end

  def test_configure_yields_events
    # act
    Lucid::Case.configure { |config| config.events.recording = :enabled }

    # assert
    assert_equal :enabled, Lucid::Case.configuration.events.recording
  end

  def test_deduplication_with_inline_store_raises_through_configure
    # act
    error = assert_raises(ArgumentError) do
      Lucid::Case.configure do |config|
        config.events.deduplication = :enabled
        config.events.store = :inline
      end
    end

    # assert
    assert_includes error.message, "deduplication"
  end

  def test_deduplication_with_outbox_store_is_valid
    # act
    Lucid::Case.configure do |config|
      config.events.deduplication = :enabled
      config.events.store = :outbox
    end

    # assert
    assert_equal :enabled, Lucid::Case.configuration.events.deduplication
  end

  def test_observers_default_to_empty_array
    # act
    observers = Lucid::Case.configuration.events.observers

    # assert
    assert_equal [], observers
  end

  def test_observers_are_not_shared_between_configurations
    # arrange
    Lucid::Case.configuration.events.observers << -> {}

    # act
    Lucid::Case.reset_configuration!

    # assert
    assert_equal [], Lucid::Case.configuration.events.observers
  end

  def test_configure_accepts_callable_observers
    # arrange
    observer = ->(event:, command:, result:) {}

    # act
    Lucid::Case.configure { |config| config.events.observers << observer }

    # assert
    assert_equal [observer], Lucid::Case.configuration.events.observers
  end

  def test_validate_accepts_object_responding_to_call
    # arrange
    observer = Class.new { def call(event:, command:, result:); end }.new

    # act
    Lucid::Case.configure { |config| config.events.observers << observer }

    # assert
    assert_equal [observer], Lucid::Case.configuration.events.observers
  end

  def test_validate_rejects_observer_that_does_not_respond_to_call
    # act
    error = assert_raises(ArgumentError) do
      Lucid::Case.configure { |config| config.events.observers << Object.new }
    end

    # assert
    assert_includes error.message, "observers"
  end

  def test_validate_rejects_symbol_observer
    # act / assert
    assert_raises(ArgumentError) do
      Lucid::Case.configure { |config| config.events.observers << :audit }
    end
  end

  def test_validate_bang_raises_for_invalid_observer
    # arrange
    events = Lucid::Case.configuration.events
    events.observers << "nope"

    # act / assert
    assert_raises(ArgumentError) { events.validate! }
  end

  def test_reset_configuration_restores_events_defaults
    # arrange
    Lucid::Case.configure do |config|
      config.events.recording = :enabled
      config.events.queue = :other
    end

    # act
    Lucid::Case.reset_configuration!

    # assert
    assert_equal :disabled, Lucid::Case.configuration.events.recording
    assert_equal :default, Lucid::Case.configuration.events.queue
  end
end
