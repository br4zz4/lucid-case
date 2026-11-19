require "test_helper"

class AttributesTest < Minitest::Test
  def test_attributes_are_readable_from_input
    # arrange
    klass = build_case do
      attributes :a, :b
      def call! = success(a: a, b: b)
    end

    # act
    result = klass.call(a: 1, b: 2)

    # assert
    assert_equal({ a: 1, b: 2 }, result.to_h)
  end

  def test_missing_attribute_is_nil
    # arrange
    klass = build_case do
      attributes :a
      def call! = success(a: a)
    end

    # act
    result = klass.call({})

    # assert
    assert_nil result[:a]
  end

  def test_call_accepts_hash_positional_argument
    # arrange
    klass = build_case do
      attributes :a
      def call! = success(a: a)
    end

    # act
    result = klass.call({ a: 5 })

    # assert
    assert_equal 5, result[:a]
  end

  def test_call_accepts_string_keys_in_hash
    # arrange
    klass = build_case do
      attributes :a
      def call! = success(a: a)
    end

    # act
    result = klass.call({ "a" => 7 })

    # assert
    assert_equal 7, result[:a]
  end

  def test_unknown_keys_are_ignored
    # arrange
    klass = build_case do
      attributes :a
      def call! = success(a: a)
    end

    # act
    result = klass.call(a: 1, zzz: 2)

    # assert
    assert_equal({ a: 1 }, result.to_h)
  end

  def test_default_value
    # arrange
    klass = build_case do
      attribute :limit, default: 10
      def call! = success(limit: limit)
    end

    # act
    result = klass.call

    # assert
    assert_equal 10, result[:limit]
  end

  def test_default_is_overridden_by_input
    # arrange
    klass = build_case do
      attribute :limit, default: 10
      def call! = success(limit: limit)
    end

    # act
    result = klass.call(limit: 3)

    # assert
    assert_equal 3, result[:limit]
  end

  def test_explicit_nil_overrides_default
    # arrange
    klass = build_case do
      attribute :limit, default: 10
      def call! = success(limit: limit)
    end

    # act
    result = klass.call(limit: nil)

    # assert
    assert_nil result[:limit]
  end

  def test_default_via_attributes_with_multiple_names
    # arrange
    klass = build_case do
      attributes :a, :b, default: 0
      def call! = success(a: a, b: b)
    end

    # act
    result = klass.call(b: 4)

    # assert
    assert_equal({ a: 0, b: 4 }, result.to_h)
  end

  def test_callable_default_is_evaluated_per_call
    # arrange
    counter = 0
    klass = build_case do
      attribute :token, default: -> { counter += 1 }
      def call! = success(token: token)
    end

    # act
    tokens = [klass.call[:token], klass.call[:token]]

    # assert
    assert_equal [1, 2], tokens
  end

  def test_value_default_is_not_shared_between_calls
    # arrange
    klass = build_case do
      attribute :items, default: []
      def call!
        items << 1
        success(items: items)
      end
    end

    # act
    first = klass.call[:items]
    second = klass.call[:items]

    # assert
    assert_equal [1], first
    assert_equal [1], second
  end

  def test_attribute_names
    # arrange
    klass = build_case do
      attributes :a, :b
    end

    # act
    names = klass.attribute_names

    # assert
    assert_equal [:a, :b], names
  end

  def test_concurrent_calls_do_not_share_values
    # arrange
    klass = build_case do
      attributes :value
      def call!
        Thread.pass
        success(value: value)
      end
    end

    # act
    results = Array.new(50) { |i| Thread.new { klass.call(value: i) } }.map(&:value)

    # assert
    assert_equal (0...50).to_a, results.map { |r| r[:value] }
  end

  def test_inheritance_isolates_definitions
    # arrange
    base = build_case("Base") { attributes :a }
    child = build_case("Child", parent: base) { attributes :b }
    sibling = build_case("Sibling", parent: base)

    # act
    names = [base.attribute_names, child.attribute_names, sibling.attribute_names]

    # assert
    assert_equal [[:a], [:a, :b], [:a]], names
  end

  def test_child_inherits_parent_attribute_values
    # arrange
    base = build_case("Base") { attributes :a }
    child = build_case("Child", parent: base) do
      attributes :b
      def call! = success(a: a, b: b)
    end

    # act
    result = child.call(a: 1, b: 2)

    # assert
    assert_equal({ a: 1, b: 2 }, result.to_h)
  end

  def test_parent_does_not_expose_child_reader
    # arrange
    base = build_case("Base") { attributes :a }
    build_case("Child", parent: base) { attributes :b }

    # act
    responds = base.new({}).respond_to?(:b)

    # assert
    refute responds
  end

  def test_sibling_does_not_see_other_sibling_attribute
    # arrange
    base = build_case("Base") { attributes :a }
    build_case("Child", parent: base) { attributes :b }
    sibling = build_case("Sibling", parent: base)

    # act
    responds = sibling.new({}).respond_to?(:b)

    # assert
    refute responds
  end

  def test_lucid_case_itself_has_no_attributes
    # arrange
    build_case { attributes :zzz }

    # act
    names = Lucid::Case.attribute_names

    # assert
    assert_empty names
  end
end
