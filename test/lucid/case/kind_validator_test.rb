require "test_helper"

class KindValidatorTest < Minitest::Test
  class Base; end
  class Child < Base; end

  def build_with(kind, message: nil)
    options = { kind: message ? { with: kind, message: message } : kind }
    build_case("Users::Kind") do
      attributes :value
      validates :value, **options
      def call! = success
    end
  end

  def test_single_class_accepts_instance
    # arrange
    klass = build_with(Integer)

    # act
    result = klass.call(value: 1)

    # assert
    assert result.success?
  end

  def test_single_class_rejects_other
    # arrange
    klass = build_with(Integer)

    # act
    result = klass.call(value: "1")

    # assert
    assert_equal :invalid_attributes, result.type
    assert_equal ["must be a kind of Integer"], result[:errors][:value]
  end

  def test_list_of_classes
    # arrange
    klass = build_with([Integer, String])

    # act
    integer = klass.call(value: 1)
    string = klass.call(value: "a")
    symbol = klass.call(value: :a)

    # assert
    assert integer.success?
    assert string.success?
    assert symbol.failure?
    assert_equal ["must be a kind of Integer, String"], symbol[:errors][:value]
  end

  def test_nil_fails
    # arrange
    klass = build_with(String)

    # act
    result = klass.call(value: nil)

    # assert
    assert result.failure?
    assert_equal :invalid_attributes, result.type
  end

  def test_subclasses_are_accepted
    # arrange
    klass = build_with(Base)

    # act
    result = klass.call(value: Child.new)

    # assert
    assert result.success?
  end

  def test_custom_message
    # arrange
    klass = build_with(Integer, message: "nope")

    # act
    result = klass.call(value: "a")

    # assert
    assert_equal ["nope"], result[:errors][:value]
  end
end
