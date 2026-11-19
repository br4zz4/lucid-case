require "test_helper"

class CacheKeyTest < Minitest::Test
  FakeParams = Struct.new(:hash) do
    def to_unsafe_h = hash
  end

  FakeRecord = Struct.new(:cache_key_with_version)

  def case_class(name = "Stats")
    build_case(name)
  end

  def key(inputs = nil, **named)
    inputs = named if inputs.nil?
    build_key(inputs)
  end

  def build_key(inputs, version: 1, scope: "global", generation: 0)
    Lucid::Case::Cache::Key.new(case_class: case_class, version: version, scope: scope, generation: generation, inputs: inputs).to_s
  end

  def test_format
    # arrange
    pattern = %r{\Alucid_case/Stats/v1/global/g0/[0-9a-f]{64}\z}

    # act
    value = key({ id: 1 })

    # assert
    assert_match pattern, value
  end

  def test_format_carries_version_scope_and_generation
    # arrange
    pattern = %r{\Alucid_case/Stats/v3/alfa/g7/[0-9a-f]{64}\z}

    # act
    value = build_key({ id: 1 }, version: 3, scope: "alfa", generation: 7)

    # assert
    assert_match pattern, value
  end

  def test_hash_order_does_not_matter
    # arrange
    one = { a: 1, b: { c: 2, d: 3 } }
    two = { b: { d: 3, c: 2 }, a: 1 }

    # act
    keys = [key(one), key(two)]

    # assert
    assert_equal keys.first, keys.last
  end

  def test_symbol_and_string_differ
    # arrange
    symbol = { status: :open }
    string = { status: "open" }

    # act
    keys = [key(symbol), key(string)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_different_values_differ
    # arrange
    one = { id: 1 }
    two = { id: 2 }

    # act
    keys = [key(one), key(two)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_array_order_matters
    # arrange
    one = { ids: [1, 2] }
    two = { ids: [2, 1] }

    # act
    keys = [key(one), key(two)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_array_is_stable
    # arrange
    one = { ids: [1, "a", :b, nil] }
    two = { ids: [1, "a", :b, nil] }

    # act
    keys = [key(one), key(two)]

    # assert
    assert_equal keys.first, keys.last
  end

  def test_date_and_time
    # arrange
    date = Date.new(2026, 1, 2)
    time = Time.utc(2026, 1, 2, 3, 4, 5)

    # act
    keys = [key(day: date), key(day: Date.new(2026, 1, 2)), key(at: time), key(at: Time.utc(2026, 1, 2, 3, 4, 5))]

    # assert
    assert_equal keys[0], keys[1]
    assert_equal keys[2], keys[3]
    refute_equal keys[0], key(day: Date.new(2026, 1, 3))
    refute_equal keys[2], key(at: time + 1)
  end

  def test_time_in_other_zone_is_equivalent
    # arrange
    utc = Time.utc(2026, 1, 2, 3, 4, 5)
    offset = Time.new(2026, 1, 2, 0, 4, 5, "-03:00")

    # act
    keys = [key(at: utc), key(at: offset)]

    # assert
    assert_equal keys.first, keys.last
  end

  def test_active_record_uses_cache_key_with_version
    # arrange
    user = User.create!(name: "Ana")

    # act
    same = [key(user: user), key(user: User.find(user.id))]
    different = key(user: FakeRecord.new("users/1-other"))

    # assert
    assert_equal same.first, same.last
    refute_equal same.first, different
  end

  def test_record_version_changes_key
    # arrange
    one = FakeRecord.new("periods/1-20260101")
    two = FakeRecord.new("periods/1-20260102")

    # act
    keys = [key(period: one), key(period: two)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_parameters_like_object
    # arrange
    one = FakeParams.new({ "b" => 1, "a" => 2 })
    two = FakeParams.new({ a: 2, b: 1 })

    # act
    keys = [key(params: one), key(params: two)]

    # assert
    assert_equal keys.first, keys.last
  end

  def test_scalars_are_distinct
    # arrange
    inputs = [nil, true, false, 0, 1, 1.5, "1", :"1", BigDecimal("2.5")]

    # act
    keys = inputs.map { |value| key(v: value) }

    # assert
    assert_equal inputs.size, keys.uniq.size
  end

  def test_proc_raises_with_path
    # arrange
    inputs = { filter: { callback: -> { 1 } } }

    # act
    error = assert_raises(Lucid::Case::Error::UncacheableInput) { key(inputs) }

    # assert
    assert_includes error.message, "inputs.filter.callback"
    assert_includes error.message, "Proc"
    assert_includes error.message, "Stats"
  end

  def test_arbitrary_object_raises_with_array_path
    # arrange
    inputs = { items: [1, Object.new] }

    # act
    error = assert_raises(Lucid::Case::Error::UncacheableInput) { key(inputs) }

    # assert
    assert_includes error.message, "inputs.items[1]"
    assert_includes error.message, "Object"
  end

  def test_string_containing_separators_does_not_collide_with_split_hash
    # arrange
    joined = { a: "x,b=s:y" }
    split = { a: "x", b: "y" }

    # act
    keys = [key(joined), key(split)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_symbol_value_and_string_value_differ
    # arrange
    symbol = { v: :a }
    string = { v: "a" }

    # act
    keys = [key(symbol), key(string)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_array_of_integer_and_string_differ
    # arrange
    integers = { v: [1] }
    mixed = { v: ["1"] }

    # act
    keys = [key(integers), key(mixed), key(v: [1, "1"])]

    # assert
    assert_equal 3, keys.uniq.size
  end

  def test_nested_array_boundaries_differ
    # arrange
    split = { v: [[1], [2]] }
    flat = { v: [[1, 2]] }

    # act
    keys = [key(split), key(flat)]

    # assert
    refute_equal keys.first, keys.last
  end

  def test_same_input_gives_same_key
    # arrange
    inputs = { a: [1, "x", { b: :c }], d: nil }

    # act
    keys = [key(inputs), key(Marshal.load(Marshal.dump(inputs)))]

    # assert
    assert_equal keys.first, keys.last
  end

  def test_hash_key_order_is_irrelevant_at_top_level
    # arrange
    one = { a: 1, b: 2, c: 3 }
    two = { c: 3, a: 1, b: 2 }

    # act
    keys = [key(one), key(two)]

    # assert
    assert_equal keys.first, keys.last
  end
end
