require "test_helper"
require "logger"
require "stringio"

class NameCollisionTest < Minitest::Test
  PRIVATE_NAMES = %i[
    run run_step run_steps run_body evaluate guarded isolated with_cache with_transaction
    cache_key log describe_data instrument_call write_cache ensure_result! refresh!
  ].freeze

  def setup
    @original_configuration = Lucid::Case.configuration
    @original_cache_in_use = Lucid::Case.instance_variable_get(:@cache_in_use)
    Lucid::Case.reset_configuration!
    @io = StringIO.new
    config = Lucid::Case.configuration
    config.logger = Logger.new(@io)
    config.logging = :enabled
    config.perform_caching = true
    config.cache_scope = :global
    config.cache_store = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Lucid::Case.instance_variable_set(:@configuration, @original_configuration)
    Lucid::Case.instance_variable_set(:@cache_in_use, @original_cache_in_use)
  end

  def define_colliding_methods(klass, names)
    klass.class_eval do
      names.each do |name|
        define_method(name) { |*| raise "user method #{name} was invoked by the gem" }
        private name
      end
    end
  end

  def stepped_command(events)
    klass = build_case("Colliding::Stepped", parent: Lucid::Case::Command) do
      attributes :log, :run, :events, :fail_with

      catch(ArgumentError) { |ctx| failure(:caught, error: ctx.error.message) }

      after_success { events << :after_success }
      after_commit { events << [:after_commit, User.connection.transaction_open?] }

      step(:first) do
        events << [:first, User.connection.transaction_open?]
        raise ArgumentError, "boom" if fail_with == :raise

        continue(first: log)
      end
      step(:second) { success(second: run) }
    end
    define_colliding_methods(klass, PRIVATE_NAMES - %i[log run])
    klass
  end

  def body_command
    klass = build_case("Colliding::Body", parent: Lucid::Case::Command) do
      attributes :events, :fail_with

      catch(ArgumentError) { |ctx| failure(:caught, error: ctx.error.message) }

      after_commit { events << [:after_commit, User.connection.transaction_open?] }

      def call!
        raise ArgumentError, "boom" if fail_with == :raise

        User.create!(name: "collision")
        events << [:body, User.connection.transaction_open?]
        success(created: true)
      end
    end
    define_colliding_methods(klass, PRIVATE_NAMES)
    klass
  end

  def colliding_query(name, stepped:)
    klass = build_case(name, parent: Lucid::Case::Query) do
      attributes :id, :log, :run
      cache duration: 5.minutes
      singleton_class.attr_accessor :calls
      self.calls = 0
    end
    if stepped
      klass.class_eval do
        step(:count) do
          self.class.calls += 1
          continue(n: self.class.calls)
        end
        step(:done) { success(id: id, log: log, run: run) }
      end
    else
      klass.class_eval do
        def call!
          self.class.calls += 1
          success(id: id, n: self.class.calls, log: log, run: run)
        end
      end
    end
    define_colliding_methods(klass, PRIVATE_NAMES - %i[log run])
    klass
  end

  def test_stepped_command_succeeds_with_user_methods_and_attributes
    # arrange
    events = []
    klass = stepped_command(events)

    # act
    result = klass.call(events: events, log: "L", run: "R")

    # assert
    assert result.success?
    assert_equal({ first: "L", second: "R" }, result.content)
    assert_equal [[:first, true], :after_success, [:after_commit, false]], events
  end

  def test_stepped_command_catch_still_works
    # arrange
    events = []
    klass = stepped_command(events)

    # act
    result = klass.call(events: events, fail_with: :raise)

    # assert
    assert result.failure?
    assert_equal :caught, result.type
    assert_equal "boom", result.content[:error]
  end

  def test_stepped_command_logs_with_logger
    # arrange
    klass = stepped_command([])

    # act
    klass.call(events: [], log: "L", run: "R")

    # assert
    assert_includes @io.string, "[Lucid::Case] Colliding::Stepped called"
    assert_includes @io.string, "step :first"
    assert_includes @io.string, "Colliding::Stepped success"
  end

  def test_call_command_runs_in_transaction_with_after_commit
    # arrange
    events = []
    klass = body_command
    before = User.count

    # act
    result = klass.call(events: events)

    # assert
    assert result.success?
    assert_equal before + 1, User.count
    assert_equal [[:body, true], [:after_commit, false]], events
  end

  def test_call_command_rolls_back_and_catches
    # arrange
    events = []
    klass = body_command

    # act
    result = klass.call(events: events, fail_with: :raise)

    # assert
    assert_equal :caught, result.type
    assert_empty events
  end

  def test_call_command_logs_with_logger
    # arrange
    klass = body_command

    # act
    klass.call(events: [])

    # assert
    assert_includes @io.string, "[Lucid::Case] Colliding::Body called"
    assert_includes @io.string, "Colliding::Body success"
  end

  def test_private_log_and_run_methods_do_not_collide
    # arrange
    klass = build_case("Colliding::PrivateLog", parent: Lucid::Case::Command) do
      def call!
        success(ok: true)
      end
    end
    define_colliding_methods(klass, %i[log run])

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_includes @io.string, "Colliding::PrivateLog success"
  end

  def test_call_query_hit_and_miss
    # arrange
    klass = colliding_query("Colliding::QueryBody", stepped: false)

    # act
    first = klass.call(id: 1, log: "L", run: "R")
    second = klass.call(id: 1, log: "L", run: "R")
    other = klass.call(id: 2, log: "L", run: "R")

    # assert
    assert_equal 2, klass.calls
    refute first.cached?
    assert second.cached?
    refute other.cached?
    assert_equal "L", second.content[:log]
    assert_equal "R", second.content[:run]
  end

  def test_stepped_query_hit_and_miss
    # arrange
    klass = colliding_query("Colliding::QuerySteps", stepped: true)

    # act
    first = klass.call(id: 1, log: "L", run: "R")
    second = klass.call(id: 1, log: "L", run: "R")

    # assert
    assert_equal 1, klass.calls
    refute first.cached?
    assert second.cached?
    assert_equal 1, second.content[:n]
  end

  def test_query_fresh_bypasses_and_rewrites_cache
    # arrange
    klass = colliding_query("Colliding::QueryFresh", stepped: false)
    klass.call(id: 1)

    # act
    refreshed = klass.fresh.call(id: 1)
    after = klass.call(id: 1)

    # assert
    assert_equal 2, klass.calls
    refute refreshed.cached?
    assert after.cached?
    assert_equal 2, after.content[:n]
  end

  def test_query_stale_invalidates_entry
    # arrange
    klass = colliding_query("Colliding::QueryStale", stepped: false)
    klass.call(id: 1)
    klass.call(id: 2)

    # act
    invalidated = klass.stale(id: 1)
    first = klass.call(id: 1)
    second = klass.call(id: 2)

    # assert
    assert invalidated
    refute first.cached?
    assert second.cached?
    assert_equal 3, klass.calls
  end

  def test_query_stale_all_invalidates_everything
    # arrange
    klass = colliding_query("Colliding::QueryStaleAll", stepped: false)
    klass.call(id: 1)

    # act
    klass.stale
    after = klass.call(id: 1)

    # assert
    refute after.cached?
    assert_equal 2, klass.calls
  end

  def test_query_logs_cache_status
    # arrange
    klass = colliding_query("Colliding::QueryLog", stepped: false)

    # act
    klass.call(id: 1)
    klass.call(id: 1)

    # assert
    assert_includes @io.string, "cache=miss"
    assert_includes @io.string, "cache=hit"
  end
end
