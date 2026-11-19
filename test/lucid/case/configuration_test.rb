require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
  end

  def teardown
    Lucid::Case.instance_variable_set(:@configuration, @original)
  end

  def test_defaults
    # arrange
    config = Lucid::Case.configuration

    # act
    values = [config.transaction, config.cache, config.cache_duration, config.cache_scope]

    # assert
    assert_equal [:enabled, :disabled, 5.minutes, nil], values
  end

  def test_configure_yields_and_sets_values
    # arrange
    scope = -> { :tenant }
    store = ActiveSupport::Cache::MemoryStore.new

    # act
    yielded = nil
    Lucid::Case.configure do |config|
      yielded = config
      config.cache_store = store
      config.transaction = :disabled
      config.cache = :enabled
      config.cache_duration = 10.minutes
      config.cache_scope = scope
    end

    # assert
    assert_same Lucid::Case.configuration, yielded
    assert_equal :disabled, yielded.transaction
    assert_equal :enabled, yielded.cache
    assert_equal 10.minutes, yielded.cache_duration
    assert_same scope, yielded.cache_scope
  end

  def test_invalid_transaction_raises
    # arrange
    config = Lucid::Case.configuration

    # act
    error = assert_raises(ArgumentError) { config.transaction = :maybe }

    # assert
    assert_includes error.message, "transaction"
    assert_equal :enabled, config.transaction
  end

  def test_invalid_cache_raises_through_configure
    # arrange
    block = proc { |config| config.cache = true }

    # act
    error = assert_raises(ArgumentError) { Lucid::Case.configure(&block) }

    # assert
    assert_includes error.message, "cache"
  end

  def test_reset_configuration
    # arrange
    Lucid::Case.configure { |config| config.transaction = :disabled }
    previous = Lucid::Case.configuration

    # act
    Lucid::Case.reset_configuration!

    # assert
    refute_same previous, Lucid::Case.configuration
    assert_equal :enabled, Lucid::Case.configuration.transaction
  end

  def test_perform_caching_defaults_to_true_without_rails_app
    # arrange
    config = Lucid::Case.configuration

    # act
    value = config.perform_caching

    # assert
    assert_equal true, value
  end

  def test_perform_caching_setter
    # arrange
    config = Lucid::Case.configuration

    # act
    config.perform_caching = false

    # assert
    assert_equal false, config.perform_caching
  end

  def test_cache_store_nil_without_rails
    # arrange
    config = Lucid::Case.configuration

    # act
    store = config.cache_store

    # assert
    assert_nil store
  end

  def test_cache_store_setter
    # arrange
    config = Lucid::Case.configuration
    store = ActiveSupport::Cache::MemoryStore.new

    # act
    config.cache_store = store

    # assert
    assert_same store, config.cache_store
  end

  def test_cache_scope_setter
    # arrange
    config = Lucid::Case.configuration

    # act
    config.cache_scope = :global

    # assert
    assert_equal :global, config.cache_scope
  end

  def test_accumulate_defaults_to_enabled
    # arrange
    config = Lucid::Case.configuration

    # act
    value = config.accumulate

    # assert
    assert_equal :enabled, value
  end

  def test_accumulate_setter
    # arrange
    config = Lucid::Case.configuration

    # act
    config.accumulate = :disabled

    # assert
    assert_equal :disabled, config.accumulate
  end

  def test_invalid_accumulate_raises
    # arrange
    config = Lucid::Case.configuration

    # act
    error = assert_raises(ArgumentError) { config.accumulate = :maybe }

    # assert
    assert_includes error.message, "accumulate"
    assert_equal :enabled, config.accumulate
  end

  def test_logging_defaults
    # arrange
    config = Lucid::Case.configuration

    # act
    values = [config.logging, config.log_level, config.log_values, config.logger]

    # assert
    assert_equal [:disabled, :info, false, nil], values
  end

  def test_logging_setters
    # arrange
    config = Lucid::Case.configuration
    logger = Logger.new(StringIO.new)

    # act
    config.logging = :enabled
    config.log_level = :debug
    config.log_values = true
    config.logger = logger
    config.filter_parameters = [:token]

    # assert
    assert_equal :enabled, config.logging
    assert_equal :debug, config.log_level
    assert_equal true, config.log_values
    assert_same logger, config.logger
    assert_equal "[FILTERED]", config.parameter_filter.filter(token: "x")[:token]
  end

  def test_invalid_logging_raises
    # arrange
    config = Lucid::Case.configuration

    # act
    error = assert_raises(ArgumentError) { config.logging = :maybe }

    # assert
    assert_includes error.message, "logging"
    assert_equal :disabled, config.logging
  end

  def test_invalid_log_level_raises
    # arrange
    config = Lucid::Case.configuration

    # act
    error = assert_raises(ArgumentError) { config.log_level = :verbose }

    # assert
    assert_includes error.message, "log_level"
    assert_equal :info, config.log_level
  end

  def test_reset_configuration_restores_accumulate
    # arrange
    Lucid::Case.configure { |config| config.accumulate = :disabled }

    # act
    Lucid::Case.reset_configuration!

    # assert
    assert_equal :enabled, Lucid::Case.configuration.accumulate
  end
end
