require "test_helper"

class ValidationsTest < Minitest::Test
  def build_validated
    build_case("Users::Validated") do
      attributes :params
      validates :params, presence: true, kind: Hash

      class << self
        attr_accessor :executed
      end

      def call!
        self.class.executed = true
        success(params: params)
      end
    end
  end

  def test_nil_params_fail_without_running_call
    # arrange
    klass = build_validated

    # act
    result = klass.call(params: nil)

    # assert
    assert result.failure?
    assert_equal :invalid_attributes, result.type
    assert_kind_of ActiveModel::Errors, result[:errors]
    assert result[:errors].added?(:params, :blank)
    refute klass.executed
  end

  def test_wrong_kind_fails_without_running_call
    # arrange
    klass = build_validated

    # act
    result = klass.call(params: "x")

    # assert
    assert result.failure?
    assert_equal :invalid_attributes, result.type
    assert_kind_of ActiveModel::Errors, result[:errors]
    assert_includes result[:errors][:params].join, "must be a kind of Hash"
    refute klass.executed
  end

  def test_valid_params_run_call
    # arrange
    klass = build_validated

    # act
    result = klass.call(params: { a: 1 })

    # assert
    assert result.success?
    assert_equal({ a: 1 }, result[:params])
    assert klass.executed
  end

  def test_anonymous_class_works
    # arrange
    klass = Class.new(Lucid::Case) do
      attributes :params
      validates :params, presence: true, kind: Hash

      def call! = success
    end

    # act
    invalid = klass.call(params: nil)
    valid = klass.call(params: { a: 1 })

    # assert
    assert_equal :invalid_attributes, invalid.type
    assert valid.success?
    assert_equal "LucidCase", klass.model_name.name
  end

  def test_named_class_model_name
    # arrange
    klass = build_case("Users::Create")

    # act
    name = klass.model_name.name

    # assert
    assert_equal "Users::Create", name
  end
end
