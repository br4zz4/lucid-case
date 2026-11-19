require "test_helper"
require "logger"
require "stringio"

class FinallyTest < Minitest::Test
  def setup
    Lucid::Case.reset_configuration!
    User.delete_all
  end

  def teardown
    Lucid::Case.reset_configuration!
    User.delete_all
  end

  def test_runs_after_success
    # arrange
    log = []
    klass = build_case("Ok", parent: Lucid::Case::Command) do
      finally { log << :finally }
      define_method(:call!) { success(done: true) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal [:finally], log
  end

  def test_runs_after_failure
    # arrange
    log = []
    klass = build_case("Ko", parent: Lucid::Case::Command) do
      finally { log << :finally }
      define_method(:call!) { failure(:nope) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal [:finally], log
  end

  def test_runs_after_uncaught_exception_and_exception_propagates
    # arrange
    log = []
    klass = build_case("Boom", parent: Lucid::Case::Command) do
      finally { log << :finally }
      define_method(:call!) { raise ArgumentError, "bad" }
    end

    # act
    error = assert_raises(ArgumentError) { klass.call }

    # assert
    assert_equal "bad", error.message
    assert_equal [:finally], log
  end

  def test_runs_after_exception_handled_by_catch
    # arrange
    log = []
    klass = build_case("Caught", parent: Lucid::Case::Command) do
      catch(Timeout::Error) { failure(:timeout) }
      finally { log << :finally }
      define_method(:call!) { raise Timeout::Error, "slow" }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :timeout, result.type
    assert_equal [:finally], log
  end

  def test_runs_after_catch_handler
    # arrange
    log = []
    klass = build_case("Order", parent: Lucid::Case::Command) do
      catch(Timeout::Error) { log << :catch; failure(:timeout) }
      finally { log << :finally }
      define_method(:call!) { raise Timeout::Error, "slow" }
    end

    # act
    klass.call

    # assert
    assert_equal %i[catch finally], log
  end

  def test_runs_blocks_in_declaration_order
    # arrange
    log = []
    klass = build_case("Many", parent: Lucid::Case::Command) do
      finally(:a) { log << :a }
      finally(:b) { log << :b }
      finally { log << :c }
      define_method(:call!) { success }
    end

    # act
    klass.call

    # assert
    assert_equal %i[a b c], log
  end

  def test_runs_outside_the_transaction
    # arrange
    log = []
    klass = build_case("Tx", parent: Lucid::Case::Command) do
      finally { log << User.connection.transaction_open? }
      define_method(:call!) do
        log << User.connection.transaction_open?
        success
      end
    end

    # act
    klass.call

    # assert
    assert_equal [true, false], log
  end

  def test_runs_outside_the_transaction_on_failure
    # arrange
    log = []
    klass = build_case("TxFail", parent: Lucid::Case::Command) do
      finally { log << User.connection.transaction_open? }
      define_method(:call!) { failure(:x) }
    end

    # act
    klass.call

    # assert
    assert_equal [false], log
  end

  def test_self_is_the_case_instance
    # arrange
    seen = []
    klass = build_case("Selfie", parent: Lucid::Case::Command) do
      attributes :token
      finally { seen << [self.class, token] }
      define_method(:call!) { success }
    end

    # act
    klass.call(token: "abc")

    # assert
    assert_equal [[klass, "abc"]], seen
  end

  def test_does_not_run_on_cache_hit
    # arrange
    config = Lucid::Case.configuration
    config.perform_caching = true
    config.cache_scope = :global
    config.cache_store = ActiveSupport::Cache::MemoryStore.new
    log = []
    klass = build_case("Cached", parent: Lucid::Case::Query) do
      attributes :id
      cache :enabled
      finally { log << :finally }
      define_method(:call!) { success(id: id) }
    end

    # act
    klass.call(id: 1)
    klass.call(id: 1)

    # assert
    assert_equal [:finally], log
  end

  def test_exception_raised_in_finally_propagates
    # arrange
    klass = build_case("Raising", parent: Lucid::Case::Command) do
      finally { raise IOError, "cleanup failed" }
      define_method(:call!) { success }
    end

    # act
    error = assert_raises(IOError) { klass.call }

    # assert
    assert_equal "cleanup failed", error.message
  end

  def test_without_block_raises_argument_error
    # arrange
    block = proc { finally(:nothing) }

    # act
    error = assert_raises(ArgumentError) { build_case(parent: Lucid::Case::Command, &block) }

    # assert
    assert_includes error.message, "finally"
  end

  def test_subclass_inherits_without_leaking_to_base
    # arrange
    log = []
    base = build_case("Base", parent: Lucid::Case::Command) do
      finally { log << :base }
      define_method(:call!) { success }
    end
    child = build_case("Child", parent: base) { finally { log << :child } }

    # act
    child.call
    child_log = log.dup
    log.clear
    base.call

    # assert
    assert_equal %i[base child], child_log
    assert_equal [:base], log
  end

  def test_works_with_steps
    # arrange
    log = []
    klass = build_case("Stepped", parent: Lucid::Case::Command) do
      step(:one) { continue(a: 1) }
      step(:two) { success(done: true) }
      finally { log << :finally }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal [:finally], log
  end

  def test_works_with_steps_that_fail
    # arrange
    log = []
    klass = build_case("SteppedFail", parent: Lucid::Case::Command) do
      step(:one) { failure(:broken) }
      finally { log << :finally }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal [:finally], log
  end

  def test_works_in_query
    # arrange
    log = []
    klass = build_case("Report", parent: Lucid::Case::Query) do
      finally { log << :finally }
      define_method(:call!) { success(rows: []) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal [:finally], log
  end

  def test_logs_finally_name_when_logging_enabled
    # arrange
    io = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(io)
    klass = build_case("Logged", parent: Lucid::Case::Command) do
      logging :enabled
      finally(:release_lock) { nil }
      define_method(:call!) { success }
    end

    # act
    klass.call

    # assert
    assert_includes io.string, "[Lucid::Case] Logged finally :release_lock"
  end

  def test_does_not_log_finally_when_logging_disabled
    # arrange
    io = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(io)
    klass = build_case("Quiet", parent: Lucid::Case::Command) do
      finally(:release_lock) { nil }
      define_method(:call!) { success }
    end

    # act
    klass.call

    # assert
    assert_equal "", io.string
  end
end
