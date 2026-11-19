require "test_helper"

class BootValidationTest < Minitest::Test
  def setup
    @original_configuration = Lucid::Case.configuration
    @original_cache_in_use = Lucid::Case.instance_variable_get(:@cache_in_use)
    @original_booted = Lucid::Case.instance_variable_get(:@booted)
    Lucid::Case.reset_configuration!
    Lucid::Case.instance_variable_set(:@booted, false)
    @config = Lucid::Case.configuration
    @config.perform_caching = true
  end

  def teardown
    Lucid::Case.instance_variable_set(:@configuration, @original_configuration)
    Lucid::Case.instance_variable_set(:@cache_in_use, @original_cache_in_use)
    Lucid::Case.instance_variable_set(:@booted, @original_booted)
  end

  def enable_cache
    @config.cache = :enabled
  end

  def test_missing_store_raises
    # arrange
    enable_cache
    @config.cache_scope = :global

    # act
    error = assert_raises(Lucid::Case::Error::CacheStoreMissing) { Lucid::Case.validate_configuration! }

    # assert
    assert_includes error.message, "nil"
  end

  def test_null_store_raises
    # arrange
    enable_cache
    @config.cache_store = ActiveSupport::Cache::NullStore.new
    @config.cache_scope = :global

    # act
    error = assert_raises(Lucid::Case::Error::CacheStoreMissing) { Lucid::Case.validate_configuration! }

    # assert
    assert_includes error.message, "NullStore"
  end

  def test_missing_scope_raises
    # arrange
    enable_cache
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new

    # act
    block = -> { Lucid::Case.validate_configuration! }

    # assert
    assert_raises(Lucid::Case::Error::MissingCacheScope, &block)
  end

  def test_global_scope_is_accepted
    # arrange
    enable_cache
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new
    @config.cache_scope = :global

    # act
    result = Lucid::Case.validate_configuration!

    # assert
    assert_same @config, result
  end

  def test_lambda_scope_is_accepted
    # arrange
    enable_cache
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new
    @config.cache_scope = -> { "alfa" }

    # act
    result = Lucid::Case.validate_configuration!

    # assert
    assert_same @config, result
  end

  def test_perform_caching_false_does_not_validate
    # arrange
    enable_cache
    @config.perform_caching = false

    # act
    result = Lucid::Case.validate_configuration!

    # assert
    assert_same @config, result
  end

  def test_cache_not_in_use_does_not_validate
    # arrange
    @config.cache_store = nil

    # act
    result = Lucid::Case.validate_configuration!

    # assert
    assert_same @config, result
  end

  def test_configure_validates
    # arrange
    block = proc { |config| config.cache = :enabled }

    # act
    error = assert_raises(Lucid::Case::Error::CacheStoreMissing) { Lucid::Case.configure(&block) }

    # assert
    assert_kind_of Lucid::Case::Error, error
  end

  def test_case_declaring_cache_before_boot_does_not_raise_until_validated
    # arrange
    build_case("Stats", parent: Lucid::Case::Query) { cache :enabled }

    # act
    error = assert_raises(Lucid::Case::Error::CacheStoreMissing) { Lucid::Case.validate_configuration! }

    # assert
    assert_kind_of Lucid::Case::Error, error
  end

  def test_case_declaring_cache_after_boot_validates_immediately
    # arrange
    Lucid::Case.send(:booted!)

    # act
    block = -> { build_case("Stats", parent: Lucid::Case::Query) { cache :enabled } }

    # assert
    assert_raises(Lucid::Case::Error::CacheStoreMissing, &block)
  end

  def test_case_declaring_duration_after_boot_validates_immediately
    # arrange
    Lucid::Case.send(:booted!)
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new

    # act
    block = -> { build_case("Stats", parent: Lucid::Case::Query) { cache duration: 1.minute } }

    # assert
    assert_raises(Lucid::Case::Error::MissingCacheScope, &block)
  end

  def test_case_declaring_cache_after_boot_passes_when_configured
    # arrange
    Lucid::Case.send(:booted!)
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new
    @config.cache_scope = :global

    # act
    klass = build_case("Stats", parent: Lucid::Case::Query) { cache :enabled }

    # assert
    assert_equal :enabled, klass.cache_setting
  end

  def test_case_disabled_after_boot_does_not_validate
    # arrange
    Lucid::Case.send(:booted!)

    # act
    klass = build_case("Stats", parent: Lucid::Case::Query) { cache :disabled }

    # assert
    assert_equal :disabled, klass.cache_setting
  end

  def test_reset_configuration_clears_cache_in_use
    # arrange
    build_case("Stats", parent: Lucid::Case::Query) { cache :enabled }

    # act
    Lucid::Case.reset_configuration!
    Lucid::Case.configuration.perform_caching = true
    result = Lucid::Case.validate_configuration!

    # assert
    assert_same Lucid::Case.configuration, result
  end
end
