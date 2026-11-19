require "test_helper"

class TransactionTest < Minitest::Test
  def setup
    User.delete_all
    Lucid::Case.reset_configuration!
  end

  def teardown
    Lucid::Case.reset_configuration!
    User.delete_all
  end

  def test_rollback_on_failure
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "Ana")
        failure(:x)
      end
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :x, result.type
    assert_equal 0, User.count
  end

  def test_commit_on_success
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call! = success(user: User.create!(name: "Ana"))
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal 1, User.count
  end

  def test_rollback_on_exception
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "Ana")
        raise "boom"
      end
    end

    # act
    error = assert_raises(RuntimeError) { klass.call }

    # assert
    assert_equal "boom", error.message
    assert_equal 0, User.count
  end

  def test_transaction_disabled_keeps_write_on_failure
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      transaction :disabled

      def call!
        User.create!(name: "failed")
        failure(:x)
      end
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal ["failed"], User.pluck(:name)
  end

  def test_global_disabled_runs_without_transaction
    # arrange
    Lucid::Case.configure { |config| config.transaction = :disabled }
    klass = build_case(parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "kept")
        failure(:x)
      end
    end

    # act
    klass.call

    # assert
    assert_equal ["kept"], User.pluck(:name)
  end

  def test_case_enabled_overrides_global_disabled
    # arrange
    Lucid::Case.configure { |config| config.transaction = :disabled }
    klass = build_case(parent: Lucid::Case::Command) do
      transaction :enabled

      def call!
        User.create!(name: "rolled")
        failure(:x)
      end
    end

    # act
    klass.call

    # assert
    assert_equal 0, User.count
  end

  def test_transactional_predicate
    # arrange
    default = build_case(parent: Lucid::Case::Command)
    disabled = build_case(parent: Lucid::Case::Command) { transaction :disabled }

    # assert
    assert default.transactional?
    refute disabled.transactional?
  end

  def test_nested_case_uses_savepoint
    # arrange
    inner = build_case("Inner", parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "B")
        failure(:inner)
      end
    end
    outer = build_case("Outer", parent: Lucid::Case::Command) do
      attributes :inner

      def call!
        User.create!(name: "A")
        inner.call
        success
      end
    end

    # act
    result = outer.call(inner: inner)

    # assert
    assert result.success?
    assert_equal ["A"], User.pluck(:name)
  end

  def test_nested_exception_rolls_back_only_inner_when_rescued
    # arrange
    inner = build_case("Inner", parent: Lucid::Case::Command) do
      def call!
        User.create!(name: "B")
        raise "inner boom"
      end
    end
    outer = build_case("Outer", parent: Lucid::Case::Command) do
      attributes :inner

      def call!
        User.create!(name: "A")
        begin
          inner.call
        rescue RuntimeError
          nil
        end
        success
      end
    end

    # act
    outer.call(inner: inner)

    # assert
    assert_equal ["A"], User.pluck(:name)
  end

  def test_transaction_in_query_raises
    # act / assert
    assert_raises(Lucid::Case::Error::SideEffectInQuery) do
      build_case(parent: Lucid::Case::Query) { transaction :enabled }
    end
  end

  def test_invalid_value_raises
    # act / assert
    assert_raises(ArgumentError) { build_case(parent: Lucid::Case::Command) { transaction :maybe } }
    assert_raises(ArgumentError) { build_case(parent: Lucid::Case::Command) { transaction true } }
  end
end
