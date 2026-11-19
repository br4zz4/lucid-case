require "test_helper"

class QueryTest < Minitest::Test
  def setup
    User.delete_all
  end

  def teardown
    User.delete_all
  end

  def test_write_raises_read_only_error_and_persists_nothing
    # arrange
    klass = build_case("Report", parent: Lucid::Case::Query) do
      def call! = success(user: User.create!(name: "Ana"))
    end

    # act
    assert_raises(ActiveRecord::ReadOnlyError) { klass.call }

    # assert
    assert_equal 0, User.count
  end

  def test_update_raises_read_only_error
    # arrange
    user = User.create!(name: "Ana")
    klass = build_case("Report", parent: Lucid::Case::Query) do
      attributes :user
      def call! = success(done: user.update!(name: "Bia"))
    end

    # act
    assert_raises(ActiveRecord::ReadOnlyError) { klass.call(user: user) }

    # assert
    assert_equal "Ana", user.reload.name
  end

  def test_reads_work
    # arrange
    User.create!(name: "Ana")
    User.create!(name: "Bia")
    klass = build_case("Report", parent: Lucid::Case::Query) do
      def call! = success(names: User.order(:name).pluck(:name), count: User.count)
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal %w[Ana Bia], result[:names]
    assert_equal 2, result[:count]
  end

  def test_writes_allowed_again_after_query
    # arrange
    klass = build_case("Report", parent: Lucid::Case::Query) do
      def call! = success(count: User.count)
    end

    # act
    klass.call
    User.create!(name: "Ana")

    # assert
    assert_equal 1, User.count
  end

  def test_writes_allowed_again_after_failed_query
    # arrange
    klass = build_case("Report", parent: Lucid::Case::Query) do
      def call! = success(user: User.create!(name: "Ana"))
    end

    # act
    assert_raises(ActiveRecord::ReadOnlyError) { klass.call }
    User.create!(name: "Bia")

    # assert
    assert_equal ["Bia"], User.pluck(:name)
  end

  def test_failure_result_from_query
    # arrange
    klass = build_case("Report", parent: Lucid::Case::Query) do
      def call! = failure(:empty)
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :empty, result.type
  end

  def test_forbidden_declarations
    # act / assert
    {
      transaction: ->(klass) { klass.transaction(:enabled) },
      after_success: ->(klass) { klass.after_success { nil } },
      after_failure: ->(klass) { klass.after_failure { nil } },
      after_commit: ->(klass) { klass.after_commit { nil } }
    }.each do |macro, declare|
      klass = build_case("Report", parent: Lucid::Case::Query)

      assert_raises(Lucid::Case::Error::SideEffectInQuery, macro.to_s) { declare.call(klass) }
    end
  end

  def test_forbidden_declarations_on_directly_declared_query
    # act / assert
    assert_raises(Lucid::Case::Error::SideEffectInQuery) do
      build_case { kind :query; after_success { nil } }
    end
    assert_raises(Lucid::Case::Error::SideEffectInQuery) do
      build_case { kind :query; transaction :disabled }
    end
  end
end
