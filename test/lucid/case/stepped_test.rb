require "test_helper"

class SteppedTest < Minitest::Test
  def setup
    @original_configuration = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
  end

  def teardown
    Lucid::Case.instance_variable_set(:@configuration, @original_configuration)
  end

  def test_single_step
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { success(a: "any") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal "any", result.content[:a]
  end

  def test_success_stops_the_pipeline
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { success(a: "one") }
      step(:two) { success(b: "two") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal "one", result.content[:a]
    assert_nil result.content[:b]
  end

  def test_failure_stops_the_pipeline
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { failure(:broken, a: "any") }
      step(:two) { success(b: "any") }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :broken, result.type
    assert_equal "any", result.content[:a]
    assert_nil result.content[:b]
  end

  def test_continue_accumulates_content
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { continue(a: "one") }
      step(:two) { continue(b: "two") }
      step(:three) { success(c: "three") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal({ a: "one", b: "two", c: "three" }, result.content)
  end

  def test_continue_without_content
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { continue }
      step(:two) { success(b: "two") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal({ b: "two" }, result.content)
  end

  def test_explicit_content_wins_over_accumulated
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { continue(a: "old", keep: "kept") }
      step(:two) { success(a: "new") }
    end

    # act
    result = klass.call

    # assert
    assert_equal "new", result.content[:a]
    assert_equal "kept", result.content[:keep]
  end

  def test_accumulated_content_is_merged_into_failure
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { continue(a: "one") }
      step(:two) { failure(:broken, b: "two") }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :broken, result.type
    assert_equal({ a: "one", b: "two" }, result.content)
  end

  def test_instance_state_is_shared_between_steps
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { @a = "value" and continue }
      step(:two) { success(b: @a) }
    end

    # act
    result = klass.call

    # assert
    assert_equal "value", result.content[:b]
  end

  def test_steps_read_attributes
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      attributes :name

      step(:one) { continue(upper: name.upcase) }
      step(:two) { success(greeting: "hi #{upper_name}") }

      def upper_name = name.upcase
    end

    # act
    result = klass.call(name: "ana")

    # assert
    assert_equal "hi ANA", result.content[:greeting]
    assert_equal "ANA", result.content[:upper]
  end

  def test_skip_to_jumps_forward
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { skip_to(:three, a: "one") }
      step(:two) { success(b: "two") }
      step(:three) { success(c: "three") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal "one", result.content[:a]
    assert_nil result.content[:b]
    assert_equal "three", result.content[:c]
  end

  def test_skip_to_chained
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { skip_to(:three, a: "one") }
      step(:two) { skip_to(:four, b: "two") }
      step(:three) { skip_to(:five, c: "three") }
      step(:four) { success(d: "four") }
      step(:five) { success(e: "five") }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal({ a: "one", c: "three", e: "five" }, result.content)
  end

  def test_skip_to_without_content
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { skip_to(:two) }
      step(:two) { success(b: "two") }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ b: "two" }, result.content)
  end

  def test_skip_to_missing_step_raises
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { skip_to(:ghost) }
      step(:two) { success }
    end

    # act
    error = assert_raises(ArgumentError) { klass.call }

    # assert
    assert_match(/ghost/, error.message)
  end

  def test_step_returning_invalid_value_raises
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { "nope" }
      step(:two) { success }
    end

    # act / assert
    assert_raises(Lucid::Case::Error::UnexpectedResult) { klass.call }
  end

  def test_step_returning_nil_raises
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { nil }
    end

    # act / assert
    assert_raises(Lucid::Case::Error::UnexpectedResult) { klass.call }
  end

  def test_pipeline_without_final_result_raises
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { continue(a: 1) }
      step(:two) { continue(b: 2) }
    end

    # act / assert
    assert_raises(Lucid::Case::Error::UnexpectedResult) { klass.call }
  end

  def test_step_without_block_raises
    # act / assert
    assert_raises(ArgumentError) { build_case(parent: Lucid::Case::Command) { step(:one) } }
  end

  def test_call_defined_after_step_raises
    # act / assert
    assert_raises(Lucid::Case::Error::AmbiguousDefinition) do
      build_case(parent: Lucid::Case::Command) do
        step(:one) { success }

        def call! = success
      end
    end
  end

  def test_step_defined_after_call_raises
    # act / assert
    assert_raises(Lucid::Case::Error::AmbiguousDefinition) do
      build_case(parent: Lucid::Case::Command) do
        def call! = success

        step(:one) { success }
      end
    end
  end

  def test_step_after_inherited_call_raises
    # arrange
    parent = build_case("ParentWithCall", parent: Lucid::Case::Command) do
      def call! = success
    end

    # act / assert
    assert_raises(Lucid::Case::Error::AmbiguousDefinition) do
      build_case("ChildWithStep", parent: parent) { step(:one) { success } }
    end
  end

  def test_call_after_inherited_step_raises
    # arrange
    parent = build_case("ParentWithStep", parent: Lucid::Case::Command) do
      step(:one) { success }
    end

    # act / assert
    assert_raises(Lucid::Case::Error::AmbiguousDefinition) do
      build_case("ChildWithCall", parent: parent) { def call! = success }
    end
  end

  def test_child_inherits_steps_without_leaking_to_base
    # arrange
    base = build_case("BaseSteps", parent: Lucid::Case::Command) do
      step(:a) { continue(a: 1) }
    end
    child = build_case("ChildSteps", parent: base) do
      step(:b) { success(b: 2) }
    end

    # act
    child_result = child.call

    # assert
    assert_equal({ a: 1, b: 2 }, child_result.content)
    assert_equal [:a], base.step_definitions.map(&:first)
    assert_equal %i[a b], child.step_definitions.map(&:first)
    assert base.stepped?
    assert_raises(Lucid::Case::Error::UnexpectedResult) { base.call }
  end

  def test_unstepped_case_is_not_stepped
    # arrange
    klass = build_case(parent: Lucid::Case::Command) { def call! = success }

    # assert
    refute klass.stepped?
  end

  def test_steps_in_command_are_transactional
    # arrange
    User.delete_all
    klass = build_case(parent: Lucid::Case::Command) do
      step(:one) { User.create!(name: "Ana") && continue }
      step(:two) { failure(:nope) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal 0, User.count
  end

  def test_steps_in_query
    # arrange
    klass = build_case(parent: Lucid::Case::Query) do
      step(:one) { continue(a: 1) }
      step(:two) { success(b: 2) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal({ a: 1, b: 2 }, result.content)
  end

  def test_steps_in_base_case
    # arrange
    klass = build_case do
      step(:one) { continue(a: 1) }
      step(:two) { success(b: 2) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ a: 1, b: 2 }, result.content)
  end

  def test_instances_do_not_share_state_between_calls
    # arrange
    klass = build_case(parent: Lucid::Case::Command) do
      attributes :value

      step(:one) { continue(v: value) }
      step(:two) { success }
    end

    # act
    first = klass.call(value: 1)
    second = klass.call(value: 2)

    # assert
    assert_equal 1, first.content[:v]
    assert_equal 2, second.content[:v]
  end

  def test_accumulates_by_default
    # arrange
    klass = build_case do
      step(:a) { continue(x: 1) }
      step(:b) { continue(y: 2) }
      step(:c) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ x: 1, y: 2, z: 3 }, result.content)
  end

  def test_failure_carries_accumulated_content_when_enabled
    # arrange
    klass = build_case do
      step(:a) { continue(x: 1) }
      step(:b) { failure(:broken, y: 2) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal({ x: 1, y: 2 }, result.content)
  end

  def test_disabled_returns_only_final_success_content
    # arrange
    klass = build_case do
      accumulate :disabled
      step(:a) { continue(x: 1) }
      step(:b) { continue(y: 2) }
      step(:c) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal({ z: 3 }, result.content)
  end

  def test_disabled_returns_only_final_failure_content
    # arrange
    klass = build_case do
      accumulate :disabled
      step(:a) { continue(x: 1) }
      step(:b) { failure(:broken, y: 2) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal({ y: 2 }, result.content)
  end

  def test_disabled_skip_to_does_not_accumulate
    # arrange
    klass = build_case do
      accumulate :disabled
      step(:a) { skip_to(:c, x: 1) }
      step(:b) { success(skipped: true) }
      step(:c) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ z: 3 }, result.content)
  end

  def test_enabled_skip_to_accumulates
    # arrange
    klass = build_case do
      accumulate :enabled
      step(:a) { skip_to(:c, x: 1) }
      step(:b) { success(skipped: true) }
      step(:c) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ x: 1, z: 3 }, result.content)
  end

  def test_disabled_keeps_instance_state_shared_between_steps
    # arrange
    klass = build_case do
      accumulate :disabled
      step(:a) { @value = 42; continue(x: 1) }
      step(:b) { success(seen: @value) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ seen: 42 }, result.content)
  end

  def test_subclass_inherits_disabled
    # arrange
    base = build_case do
      accumulate :disabled
    end
    child = Class.new(base) do
      step(:a) { continue(x: 1) }
      step(:b) { success(z: 3) }
    end

    # act
    result = child.call

    # assert
    assert_equal({ z: 3 }, result.content)
  end

  def test_subclass_can_re_enable_without_affecting_base
    # arrange
    base = build_case do
      accumulate :disabled
    end
    child = Class.new(base) do
      accumulate :enabled
      step(:a) { continue(x: 1) }
      step(:b) { success(z: 3) }
    end
    sibling = Class.new(base) do
      step(:a) { continue(x: 1) }
      step(:b) { success(z: 3) }
    end

    # act
    child_result = child.call
    sibling_result = sibling.call

    # assert
    assert_equal({ x: 1, z: 3 }, child_result.content)
    assert_equal({ z: 3 }, sibling_result.content)
    assert_equal false, base.accumulating?
  end

  def test_global_config_disabled_becomes_default
    # arrange
    Lucid::Case.configure { |config| config.accumulate = :disabled }
    klass = build_case do
      step(:a) { continue(x: 1) }
      step(:b) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ z: 3 }, result.content)
  end

  def test_case_setting_overrides_global_config
    # arrange
    Lucid::Case.configure { |config| config.accumulate = :disabled }
    klass = build_case do
      accumulate :enabled
      step(:a) { continue(x: 1) }
      step(:b) { success(z: 3) }
    end

    # act
    result = klass.call

    # assert
    assert_equal({ x: 1, z: 3 }, result.content)
  end

  def test_invalid_accumulate_value_raises
    # arrange
    klass = build_case

    # act
    error = assert_raises(ArgumentError) { klass.accumulate(:maybe) }

    # assert
    assert_includes error.message, "accumulate"
  end
end
