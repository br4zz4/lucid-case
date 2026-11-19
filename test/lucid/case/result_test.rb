require "test_helper"

class ResultTest < Minitest::Test
  def success_result(**content)
    Lucid::Case::Result.new(success: true, type: :ok, content: content)
  end

  def failure_result(type = :error, **content)
    Lucid::Case::Result.new(success: false, type: type, content: content)
  end

  def test_success_flags
    # arrange
    result = success_result(id: 1)

    # act
    flags = [result.success?, result.failure?, result.type]

    # assert
    assert_equal [true, false, :ok], flags
  end

  def test_failure_flags
    # arrange
    result = failure_result(:not_found, id: 1)

    # act
    flags = [result.success?, result.failure?, result.type]

    # assert
    assert_equal [false, true, :not_found], flags
  end

  def test_content_accessors
    # arrange
    result = success_result(id: 1, name: "Ana")

    # act
    values = [result.content, result.data, result[:id], result[:name], result.to_h]

    # assert
    assert_equal [{ id: 1, name: "Ana" }, { id: 1, name: "Ana" }, 1, "Ana", { id: 1, name: "Ana" }], values
  end

  def test_missing_key_is_nil
    # arrange
    result = success_result(id: 1)

    # act
    value = result[:other]

    # assert
    assert_nil value
  end

  def test_on_success_runs_block_and_returns_self
    # arrange
    result = success_result(id: 1)
    received = nil

    # act
    returned = result.on_success { |r| received = r }

    # assert
    assert_same result, returned
    assert_same result, received
  end

  def test_on_success_skips_block_on_failure
    # arrange
    result = failure_result(:x)
    called = false

    # act
    result.on_success { called = true }

    # assert
    refute called
  end

  def test_on_failure_without_type_runs_for_any_failure
    # arrange
    result = failure_result(:x)
    called = false

    # act
    returned = result.on_failure { called = true }

    # assert
    assert called
    assert_same result, returned
  end

  def test_on_failure_with_matching_type_runs
    # arrange
    result = failure_result(:not_found, id: 1)
    received = nil

    # act
    result.on_failure(:not_found) { |r| received = r[:id] }

    # assert
    assert_equal 1, received
  end

  def test_on_failure_with_other_type_skips
    # arrange
    result = failure_result(:not_found)
    called = false

    # act
    result.on_failure(:other) { called = true }

    # assert
    refute called
  end

  def test_on_failure_skips_on_success
    # arrange
    result = success_result
    called = false

    # act
    result.on_failure { called = true }

    # assert
    refute called
  end

  def test_callbacks_are_chainable
    # arrange
    result = failure_result(:not_found, id: 1)
    calls = []

    # act
    result.on_success { calls << :success }
          .on_failure(:other) { calls << :other }
          .on_failure(:not_found) { calls << :not_found }

    # assert
    assert_equal [:not_found], calls
  end

  def test_deconstruct_keys_with_hash_pattern
    # arrange
    result = failure_result(:not_found, id: 1)

    # act
    matched = case result
              in { type: :not_found, id: } then id
              else :no_match
              end

    # assert
    assert_equal 1, matched
  end

  def test_deconstruct_keys_exposes_success
    # arrange
    result = success_result(user: "Ana")

    # act
    matched = case result
              in { success: true, user: } then user
              else :no_match
              end

    # assert
    assert_equal "Ana", matched
  end

  def test_not_cached_by_default
    # arrange
    result = success_result

    # act
    cached = result.cached?

    # assert
    refute cached
    assert_nil result.cached_at
    assert_nil result.expires_at
  end

  def test_result_is_frozen
    # arrange
    result = success_result(id: 1)

    # act
    frozen = [result.frozen?, result.content.frozen?]

    # assert
    assert_equal [true, true], frozen
  end

  def test_content_does_not_alias_input
    # arrange
    source = { id: 1 }
    result = Lucid::Case::Result.new(success: true, type: :ok, content: source)

    # act
    source[:id] = 2

    # assert
    assert_equal 1, result[:id]
  end

  def test_cannot_mutate_result
    # arrange
    result = success_result(id: 1)

    # act
    error = assert_raises(FrozenError) { result.instance_variable_set(:@type, :changed) }

    # assert
    assert_kind_of FrozenError, error
  end
end
