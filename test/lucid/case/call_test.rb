require "test_helper"

class CallTest < Minitest::Test
  def test_success
    # arrange
    klass = build_case("Users::Create") do
      attributes :params
      def call! = success(user: User.create!(params))
    end

    # act
    result = klass.call(params: { name: "Ana" })

    # assert
    assert result.success?
    assert_equal :ok, result.type
    assert_equal "Ana", result[:user].name
    assert result[:user].persisted?
  end

  def test_typed_failure
    # arrange
    klass = build_case do
      def call! = failure(:not_found, id: 1)
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :not_found, result.type
    assert_equal 1, result[:id]
  end

  def test_typed_failure_callbacks
    # arrange
    klass = build_case do
      def call! = failure(:not_found, id: 1)
    end
    calls = []

    # act
    klass.call
         .on_failure(:not_found) { calls << :not_found }
         .on_failure(:other) { calls << :other }
         .on_success { calls << :success }

    # assert
    assert_equal [:not_found], calls
  end

  def test_failure_without_type_defaults_to_error
    # arrange
    klass = build_case do
      def call! = failure(reason: "x")
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :error, result.type
    assert_equal "x", result[:reason]
  end

  def test_nil_return_raises_unexpected_result
    # arrange
    klass = build_case("NilCase") do
      def call! = nil
    end

    # act
    error = assert_raises(Lucid::Case::Error::UnexpectedResult) { klass.call }

    # assert
    assert_includes error.message, "NilCase"
  end

  def test_hash_return_raises_unexpected_result
    # arrange
    klass = build_case do
      def call! = { ok: true }
    end

    # act
    action = -> { klass.call }

    # assert
    assert_raises(Lucid::Case::Error::UnexpectedResult, &action)
  end

  def test_unexpected_result_is_a_lucid_error
    # arrange
    ancestors = Lucid::Case::Error::UnexpectedResult.ancestors

    # act
    included = ancestors.include?(Lucid::Case::Error)

    # assert
    assert included
  end

  def test_result_carries_case_class
    # arrange
    klass = build_case { def call! = success }

    # act
    result = klass.call

    # assert
    assert_same klass, result.case_class
  end

  def test_failure_result_carries_case_class
    # arrange
    klass = build_case { def call! = failure(:x) }

    # act
    result = klass.call

    # assert
    assert_same klass, result.case_class
  end

  def test_subclass_result_carries_subclass
    # arrange
    base = build_case("Base") { def call! = success }
    child = build_case("Child", parent: base)

    # act
    result = child.call

    # assert
    assert_same child, result.case_class
  end

  def test_call_without_implementation_raises_not_implemented
    # arrange
    klass = build_case("Empty")

    # act
    action = -> { klass.call }

    # assert
    assert_raises(NotImplementedError, &action)
  end

  def test_result_is_frozen_after_call
    # arrange
    klass = build_case { def call! = success(a: 1) }

    # act
    result = klass.call

    # assert
    assert result.frozen?
  end
end
