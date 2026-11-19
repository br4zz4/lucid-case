require "test_helper"

module CatchingFixtures
  module Bar
    class Error < StandardError; end
  end

  class Other < StandardError; end
end

class CatchingTest < Minitest::Test
  def setup
    User.delete_all
  end

  def teardown
    User.delete_all
  end

  def test_catch_returning_result
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise Timeout::Error, "slow" }

      catch(Timeout::Error) { |ctx| failure(:timeout, error: ctx.error.message) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :timeout, result.type
    assert_equal "slow", result.content[:error]
  end

  def test_catch_returning_success_result
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise "boom" }

      catch(RuntimeError) { success(recovered: true) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal true, result.content[:recovered]
  end

  def test_handler_without_result_becomes_exception_failure
    # arrange
    seen = []
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise StandardError, "any error" }

      catch(StandardError) { |ctx| seen << ctx.error.class }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :exception, result.type
    assert_instance_of StandardError, result.content[:error]
    assert_equal "any error", result.content[:error].message
    assert_equal [StandardError], seen
  end

  def test_unmatched_exception_propagates
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise StandardError, "any error" }

      catch(ArgumentError) { failure(:never) }
    end

    # act / assert
    assert_raises(StandardError) { klass.call }
  end

  def test_exception_without_any_catch_propagates
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = raise(KeyError, "missing")
    end

    # act
    error = assert_raises(KeyError) { klass.call }

    # assert
    assert_equal "missing", error.message
  end

  def test_namespaced_class
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise CatchingFixtures::Bar::Error, "deep" }

      catch(CatchingFixtures::Bar::Error) { |ctx| failure(:bar, error: ctx.error.message) }
    end

    # act
    result = klass.call

    # assert
    assert_equal :bar, result.type
    assert_equal "deep", result.content[:error]
  end

  def test_two_handlers_same_type_run_in_order_and_last_result_wins
    # arrange
    order = []
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise CatchingFixtures::Bar::Error }

      catch(CatchingFixtures::Bar::Error) do
        order << :first
        failure(:first)
      end

      catch(CatchingFixtures::Bar::Error) do
        order << :second
        failure(:second)
      end
    end

    # act
    result = klass.call

    # assert
    assert_equal %i[first second], order
    assert_equal :second, result.type
  end

  def test_last_handler_without_result_keeps_previous_result
    # arrange
    order = []
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise CatchingFixtures::Other }

      catch(CatchingFixtures::Other) do
        order << :first
        failure(:first)
      end

      catch(CatchingFixtures::Other) { order << :second }
    end

    # act
    result = klass.call

    # assert
    assert_equal %i[first second], order
    assert_equal :first, result.type
  end

  def test_handler_that_does_not_match_is_skipped
    # arrange
    order = []
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { raise CatchingFixtures::Other }

      catch(CatchingFixtures::Bar::Error) { order << :bar }
      catch(CatchingFixtures::Other) { failure(:other) }
    end

    # act
    result = klass.call

    # assert
    assert_empty order
    assert_equal :other, result.type
  end

  def test_catch_in_case_with_call_bang
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = raise(ArgumentError, "bad")

      catch(ArgumentError) { |ctx| failure(:bad_arg, error: ctx.error.message) }
    end

    # act
    result = klass.call

    # assert
    assert_equal :bad_arg, result.type
    assert_equal "bad", result.content[:error]
  end

  def test_catch_with_several_classes
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      attributes :error_class

      def call! = raise(error_class, "x")

      catch(ArgumentError, KeyError) { |ctx| failure(:multi, error: ctx.error.class.name) }
    end

    # act
    first = klass.call(error_class: ArgumentError)
    second = klass.call(error_class: KeyError)

    # assert
    assert_equal :multi, first.type
    assert_equal "ArgumentError", first.content[:error]
    assert_equal :multi, second.type
    assert_equal "KeyError", second.content[:error]
    assert_raises(RuntimeError) { klass.call(error_class: RuntimeError) }
  end

  def test_catch_matches_subclasses
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = raise(KeyError, "k")

      catch(IndexError) { failure(:index) }
    end

    # act
    result = klass.call

    # assert
    assert_equal :index, result.type
  end

  def test_catch_without_class_raises
    # act / assert
    assert_raises(ArgumentError) do
      build_case(parent: Lucid::Case::Command) { catch { failure(:x) } }
    end
  end

  def test_catch_without_block_raises
    # act / assert
    assert_raises(ArgumentError) do
      build_case(parent: Lucid::Case::Command) { catch(StandardError) }
    end
  end

  def test_exception_rolls_back_before_catch_runs
    # arrange
    seen = []
    klass = build_case(parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "Ana")
        raise "boom"
      end

      catch(RuntimeError) do
        seen << User.count
        failure(:caught)
      end
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :caught, result.type
    assert_equal [0], seen
    assert_equal 0, User.count
  end

  def test_catch_can_persist_after_rollback
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "inside")
        raise "boom"
      end

      catch(RuntimeError) do
        User.create!(name: "audit")
        failure(:caught)
      end
    end

    # act
    klass.call

    # assert
    assert_equal ["audit"], User.pluck(:name)
  end

  def test_context_exposes_case_instance
    # arrange
    captured = nil
    klass = build_case(parent: Lucid::Case::Command) do
      attributes :value

      def call! = raise("boom")

      catch(RuntimeError) do |ctx|
        captured = ctx.case
        failure(:caught)
      end
    end

    # act
    klass.call(value: 7)

    # assert
    assert_instance_of klass, captured
    assert_equal 7, captured.value
  end

  def test_handler_runs_with_case_as_self
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = raise("boom")

      def label = "from instance"

      catch(RuntimeError) { failure(:caught, label: label) }
    end

    # act
    result = klass.call

    # assert
    assert_equal "from instance", result.content[:label]
  end

  def test_child_inherits_handlers_without_leaking_to_base
    # arrange
    base = build_case("BaseCatch", parent: Lucid::Case::Command) do
      def call! = raise(ArgumentError, "x")

      catch(ArgumentError) { failure(:base) }
    end
    child = build_case("ChildCatch", parent: base) do
      catch(ArgumentError) { failure(:child) }
    end

    # act
    base_result = base.call
    child_result = child.call

    # assert
    assert_equal :base, base_result.type
    assert_equal :child, child_result.type
  end

  def test_no_exception_leaves_result_untouched
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = success(a: 1)

      catch(StandardError) { failure(:never) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal 1, result.content[:a]
  end
end
