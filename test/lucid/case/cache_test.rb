require "test_helper"
require "active_support/testing/time_helpers"

ActiveRecord::Schema.define do
  create_table :cache_periods, force: true do |t|
    t.string :name
    t.timestamps
  end
end

class CachePeriod < ActiveRecord::Base; end

class CacheTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  def setup
    @original_configuration = Lucid::Case.configuration
    @original_cache_in_use = Lucid::Case.instance_variable_get(:@cache_in_use)
    Lucid::Case.reset_configuration!
    @store = ActiveSupport::Cache::MemoryStore.new
    config = Lucid::Case.configuration
    config.cache_store = @store
    config.cache_scope = :global
    config.perform_caching = true
    @events = []
    @subscription = ActiveSupport::Notifications.subscribe("call.lucid_case") { |*args| @events << args.last }
    CachePeriod.delete_all
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscription)
    Lucid::Case.instance_variable_set(:@configuration, @original_configuration)
    Lucid::Case.instance_variable_set(:@cache_in_use, @original_cache_in_use)
    Thread.current[:tenant] = nil
    travel_back
    CachePeriod.delete_all
  end

  def build_query(name = "Stats", parent: Lucid::Case::Query, &block)
    klass = build_case(name, parent: parent)
    klass.singleton_class.attr_accessor :calls
    klass.calls = 0
    klass.class_eval(&block) if block
    klass
  end

  def counting_query(name = "Stats", &block)
    build_query(name) do
      attributes :id
      def call!
        self.class.calls += 1
        success(id: id, run: self.class.calls)
      end
      class_eval(&block) if block
    end
  end

  def test_hit_runs_once_and_returns_cached_result
    # arrange
    klass = counting_query { cache duration: 5.minutes }

    # act
    first = klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 1, klass.calls
    refute first.cached?
    assert second.cached?
    assert_equal first.content, second.content
    refute_nil second.cached_at
    refute_nil second.expires_at
    assert_nil first.cached_at
    assert_equal klass, second.case_class
  end

  def test_different_inputs_do_not_mix
    # arrange
    klass = counting_query { cache :enabled }

    # act
    one = klass.call(id: 1)
    two = klass.call(id: 2)
    again = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    assert_equal 1, one[:id]
    assert_equal 2, two[:id]
    assert again.cached?
    assert_equal 1, again[:id]
  end

  def test_changed_record_invalidates
    # arrange
    period = CachePeriod.create!(name: "A")
    klass = build_query("ByPeriod") do
      attributes :period
      cache :enabled
      def call!
        self.class.calls += 1
        success(name: period.name)
      end
    end
    klass.call(period: period)

    # act
    period.update_columns(updated_at: period.updated_at + 1.hour)
    result = klass.call(period: period.reload)

    # assert
    assert_equal 2, klass.calls
    refute result.cached?
  end

  def test_unchanged_record_hits
    # arrange
    period = CachePeriod.create!(name: "A")
    klass = build_query("ByPeriod") do
      attributes :period
      cache :enabled
      def call!
        self.class.calls += 1
        success(name: period.name)
      end
    end
    klass.call(period: period)

    # act
    result = klass.call(period: CachePeriod.find(period.id))

    # assert
    assert_equal 1, klass.calls
    assert result.cached?
  end

  def test_scope_isolates_same_input
    # arrange
    Lucid::Case.configuration.cache_scope = -> { Thread.current[:tenant] }
    klass = counting_query { cache :enabled }
    Thread.current[:tenant] = "alfa"
    klass.call(id: 1)
    Thread.current[:tenant] = "beta"

    # act
    other = klass.call(id: 1)
    Thread.current[:tenant] = "alfa"
    same = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute other.cached?
    assert same.cached?
  end

  def test_fresh_runs_and_rewrites
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)

    # act
    fresh = klass.fresh.call(id: 1)
    after = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute fresh.cached?
    assert after.cached?
    assert_equal 2, after[:run]
  end

  def test_stale_removes_only_that_entry
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)
    klass.call(id: 2)

    # act
    result = klass.stale(id: 1)
    first = klass.call(id: 1)
    second = klass.call(id: 2)

    # assert
    assert_equal true, result
    refute first.cached?
    assert second.cached?
  end

  def test_stale_returns_false_without_entry
    # arrange
    klass = counting_query { cache :enabled }

    # act
    result = klass.stale(id: 99)

    # assert
    assert_equal false, result
  end

  def test_stale_runs_again_on_next_call
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)

    # act
    klass.stale(id: 1)
    klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
  end

  def test_stale_without_attributes_invalidates_single_entry
    # arrange
    klass = build_query("NoAttrs") do
      cache :enabled
      def call!
        self.class.calls += 1
        success(run: self.class.calls)
      end
    end
    klass.call

    # act
    result = klass.stale
    after = klass.call

    # assert
    assert_equal true, result
    assert_equal 2, klass.calls
    refute after.cached?
  end

  def test_stale_without_params_invalidates_all_entries
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)
    klass.call(id: 2)

    # act
    result = klass.stale
    first = klass.call(id: 1)
    second = klass.call(id: 2)

    # assert
    assert_equal true, result
    refute first.cached?
    refute second.cached?
  end

  def test_repeated_stale_increments_generation_monotonically
    # arrange
    klass = counting_query { cache :enabled }
    store = Lucid::Case::Cache::Store.new(klass)
    generations = []

    # act
    5.times do
      klass.call(id: 1)
      klass.stale
      generations << store.generation("global")
    end

    # assert
    assert_equal [1, 2, 3, 4, 5], generations
    refute klass.call(id: 1).cached?
  end

  def test_concurrent_stale_increments_generation_once_per_call
    # arrange
    klass = counting_query { cache :enabled }
    store = Lucid::Case::Cache::Store.new(klass)
    threads = 20
    klass.call(id: 1)

    # act
    results = Array.new(threads) do
      Thread.new do
        klass.call(id: 1)
        klass.stale
        store.generation("global")
      end
    end.map(&:value)
    after = klass.call(id: 1)

    # assert
    assert_equal threads, store.generation("global")
    assert_equal threads, results.max
    refute after.cached?
  end

  def test_stale_without_params_invalidates_current_scope_only
    # arrange
    Lucid::Case.configuration.cache_scope = -> { Thread.current[:tenant] }
    klass = counting_query { cache :enabled }
    Thread.current[:tenant] = "alfa"
    klass.call(id: 1)
    Thread.current[:tenant] = "beta"
    klass.call(id: 1)

    # act
    result = klass.stale
    beta = klass.call(id: 1)
    Thread.current[:tenant] = "alfa"
    alfa = klass.call(id: 1)

    # assert
    assert_equal true, result
    refute beta.cached?
    assert alfa.cached?
  end

  def test_version_bump_invalidates
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)

    # act
    klass.cache version: 2
    result = klass.call(id: 1)
    again = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute result.cached?
    assert again.cached?
  end

  def test_failure_is_not_cached
    # arrange
    klass = build_query("Failing") do
      cache :enabled
      def call!
        self.class.calls += 1
        failure(:nope)
      end
    end

    # act
    first = klass.call
    second = klass.call

    # assert
    assert_equal 2, klass.calls
    assert first.failure?
    refute second.cached?
  end

  def test_uncacheable_input_raises
    # arrange
    klass = counting_query { cache :enabled }

    # act
    error = assert_raises(Lucid::Case::Error::UncacheableInput) { klass.call(id: -> { 1 }) }

    # assert
    assert_includes error.message, "inputs.id"
    assert_equal 0, klass.calls
  end

  def test_disabled_in_case_runs_every_time
    # arrange
    klass = counting_query { cache :disabled }

    # act
    first = klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute first.cached?
    refute second.cached?
  end

  def test_perform_caching_false_runs_every_time
    # arrange
    Lucid::Case.configuration.perform_caching = false
    klass = counting_query { cache :enabled }

    # act
    klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute second.cached?
  end

  def test_global_default_enabled_caches_without_declaration
    # arrange
    Lucid::Case.configure { |config| config.cache = :enabled }
    klass = counting_query

    # act
    klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 1, klass.calls
    assert second.cached?
  end

  def test_case_disabled_overrides_global_enabled
    # arrange
    Lucid::Case.configure { |config| config.cache = :enabled }
    klass = counting_query { cache :disabled }

    # act
    klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute second.cached?
  end

  def test_default_disabled_does_not_cache_without_declaration
    # arrange
    klass = counting_query

    # act
    klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute second.cached?
  end

  def test_duration_implies_enabled
    # arrange
    klass = counting_query { cache duration: 10.minutes }

    # act
    klass.call(id: 1)
    second = klass.call(id: 1)

    # assert
    assert_equal :enabled, klass.cache_setting
    assert second.cached?
  end

  def test_duration_expires
    # arrange
    klass = counting_query { cache duration: 5.minutes }
    klass.call(id: 1)

    # act
    travel 6.minutes
    result = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute result.cached?
  end

  def test_expires_at_reflects_duration
    # arrange
    klass = counting_query { cache duration: 5.minutes }
    klass.call(id: 1)

    # act
    result = klass.call(id: 1)

    # assert
    assert_in_delta 5.minutes.to_f, result.expires_at - result.cached_at, 0.001
  end

  def test_command_cache_raises
    # arrange
    parent = Lucid::Case::Command

    # act
    error = assert_raises(Lucid::Case::Error::CacheOnCommand) { build_case("Cmd", parent: parent) { cache :enabled } }

    # assert
    assert_includes error.message, "Cmd"
  end

  def test_command_cache_with_duration_raises
    # arrange
    parent = Lucid::Case::Command

    # act
    block = -> { build_case("Cmd", parent: parent) { cache duration: 1.minute } }

    # assert
    assert_raises(Lucid::Case::Error::CacheOnCommand, &block)
  end

  def test_command_has_no_cache_class_methods
    # arrange
    klass = build_case("Cmd", parent: Lucid::Case::Command)

    # act
    errors = %i[fresh stale].map { |name| assert_raises(NoMethodError) { klass.public_send(name) } }

    # assert
    assert_equal 2, errors.size
  end

  def test_instrumentation_miss_then_hit
    # arrange
    klass = counting_query { cache :enabled }

    # act
    klass.call(id: 1)
    klass.call(id: 1)

    # assert
    assert_equal %i[miss hit], @events.map { |event| event[:cache] }
  end

  def test_instrumentation_bypass_for_fresh
    # arrange
    klass = counting_query { cache :enabled }

    # act
    klass.fresh.call(id: 1)

    # assert
    assert_equal [:bypass], @events.map { |event| event[:cache] }
  end

  def test_instrumentation_nil_when_disabled
    # arrange
    klass = counting_query { cache :disabled }

    # act
    klass.call(id: 1)

    # assert
    assert_equal [nil], @events.map { |event| event[:cache] }
  end

  def test_hit_does_not_run_body
    # arrange
    klass = counting_query { cache :enabled }
    klass.call(id: 1)

    # act
    klass.call(id: 1)

    # assert
    assert_equal 1, klass.calls
  end

  def period_grade_query(name = "ByPeriodGrade")
    build_query(name) do
      attributes :period, :grade
      cache :enabled
      def call!
        self.class.calls += 1
        success(period: period, grade: grade)
      end
    end
  end

  def test_stale_with_attribute_name_invalidates_every_value
    # arrange
    klass = period_grade_query
    klass.call(period: 1, grade: 1)
    klass.call(period: 2, grade: 1)
    klass.call(period: 3, grade: 2)

    # act
    result = klass.stale(:period)
    first = klass.call(period: 1, grade: 1)
    second = klass.call(period: 2, grade: 1)
    third = klass.call(period: 3, grade: 2)

    # assert
    assert_equal true, result
    refute first.cached?
    refute second.cached?
    refute third.cached?
    assert_equal 6, klass.calls
  end

  def test_stale_with_multiple_attribute_names
    # arrange
    klass = period_grade_query
    klass.call(period: 1, grade: 1)

    # act
    result = klass.stale(:period, :grade)
    after = klass.call(period: 1, grade: 1)

    # assert
    assert_equal true, result
    refute after.cached?
  end

  def test_stale_with_attribute_name_does_not_affect_other_scopes
    # arrange
    Lucid::Case.configuration.cache_scope = -> { Thread.current[:tenant] }
    klass = period_grade_query
    Thread.current[:tenant] = "alfa"
    klass.call(period: 1, grade: 1)
    Thread.current[:tenant] = "beta"
    klass.call(period: 1, grade: 1)

    # act
    klass.stale(:period)
    beta = klass.call(period: 1, grade: 1)
    Thread.current[:tenant] = "alfa"
    alfa = klass.call(period: 1, grade: 1)

    # assert
    refute beta.cached?
    assert alfa.cached?
  end

  def test_stale_with_unknown_attribute_name_raises
    # arrange
    klass = period_grade_query

    # act
    error = assert_raises(ArgumentError) { klass.stale(:unknown) }

    # assert
    assert_includes error.message, ":unknown"
  end

  def test_stale_with_names_mixed_with_inputs_raises
    # arrange
    klass = period_grade_query
    klass.call(period: 1, grade: 1)

    # act
    error = assert_raises(ArgumentError) { klass.stale(:period, grade: 1) }
    after = klass.call(period: 1, grade: 1)

    # assert
    assert_kind_of ArgumentError, error
    assert after.cached?
  end

  def test_stale_with_inputs_still_invalidates_only_that_entry
    # arrange
    klass = period_grade_query
    klass.call(period: 1, grade: 1)
    klass.call(period: 2, grade: 1)

    # act
    result = klass.stale(period: 1, grade: 1)
    first = klass.call(period: 1, grade: 1)
    second = klass.call(period: 2, grade: 1)

    # assert
    assert_equal true, result
    refute first.cached?
    assert second.cached?
  end

  def test_stale_with_attribute_name_on_command_raises
    # arrange
    klass = build_case("Cmd", parent: Lucid::Case::Command) { attributes :period }

    # act
    block = -> { klass.stale(:period) }

    # assert
    assert_raises(NoMethodError, &block)
  end
end
