require "test_helper"
require "logger"
require "stringio"

class LoggingTest < Minitest::Test
  def setup
    Lucid::Case.reset_configuration!
    @io = StringIO.new
    @config = Lucid::Case.configuration
    @config.logger = Logger.new(@io)
    @config.perform_caching = true
    @config.cache_scope = :global
    @config.cache_store = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Lucid::Case.reset_configuration!
  end

  def output
    @io.string
  end

  def lines
    output.lines.map(&:chomp)
  end

  def simple_case(name = "Simple", parent: Lucid::Case::Command, &block)
    build_case(name, parent: parent) do
      attributes :token, :name
      def call!
        success(token: token, name: name)
      end
      class_eval(&block) if block
    end
  end

  def test_disabled_by_default_logs_nothing
    # arrange
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_equal "", output
  end

  def test_global_enabled_logs_call_and_result
    # arrange
    @config.logging = :enabled
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_equal 2, lines.size
    assert_match(/INFO -- : \[Lucid::Case\] Simple called input=\[:token, :name\]/, lines[0])
    assert_match(/\[Lucid::Case\] Simple success content=\[:token, :name\] in \d+(\.\d+)?ms/, lines[1])
  end

  def test_case_enabled_with_global_disabled_logs
    # arrange
    klass = simple_case { logging :enabled }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_includes output, "[Lucid::Case] Simple called"
    assert_includes output, "[Lucid::Case] Simple success"
  end

  def test_case_disabled_with_global_enabled_is_silent
    # arrange
    @config.logging = :enabled
    klass = simple_case { logging :disabled }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_equal "", output
  end

  def test_subclass_inherits_logging_setting
    # arrange
    parent = simple_case("Parent") { logging :enabled }
    child = build_case("Child", parent: parent)

    # act
    child.call(token: "secret", name: "any")

    # assert
    assert_includes output, "[Lucid::Case] Child called"
  end

  def test_subclass_can_override_inherited_setting
    # arrange
    parent = simple_case("Parent") { logging :enabled }
    child = build_case("Child", parent: parent) { logging :disabled }

    # act
    child.call(token: "secret", name: "any")

    # assert
    assert_equal "", output
  end

  def test_invalid_case_logging_value_raises
    # arrange
    block = proc { logging :maybe }

    # act
    error = assert_raises(ArgumentError) { build_case(&block) }

    # assert
    assert_includes error.message, "logging"
  end

  def test_values_are_not_logged_by_default
    # arrange
    @config.logging = :enabled
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    refute_includes output, "secret"
  end

  def test_log_values_shows_values_and_filters_parameters
    # arrange
    @config.logging = :enabled
    @config.log_values = true
    @config.filter_parameters = [:token]
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    refute_includes output, "secret"
    assert_includes output, "[FILTERED]"
    assert_includes output, "any"
  end

  def test_steps_are_logged_in_order
    # arrange
    @config.logging = :enabled
    klass = build_case("Pipeline", parent: Lucid::Case::Command) do
      step(:one) { continue(a: 1) }
      step(:two) { skip_to(:four, b: 2) }
      step(:three) { success(never: true) }
      step(:four) { success(done: true) }
    end

    # act
    klass.call

    # assert
    step_lines = lines.grep(/ step /)
    assert_equal 3, step_lines.size
    assert_match(/step :one -> continue/, step_lines[0])
    assert_match(/step :two -> skip_to\(:four\)/, step_lines[1])
    assert_match(/step :four -> success content=\[:done\]/, step_lines[2])
  end

  def test_failure_step_is_logged
    # arrange
    @config.logging = :enabled
    klass = build_case("Pipeline", parent: Lucid::Case::Command) do
      step(:one) { failure(:broken, reason: "any") }
    end

    # act
    klass.call

    # assert
    assert_match(/step :one -> failure\(:broken\) content=\[:reason\]/, output)
    assert_match(/Pipeline failure\(:broken\) content=\[:reason\] in /, output)
  end

  def test_raising_step_with_catch_logs_warnings_and_failure
    # arrange
    @config.logging = :enabled
    klass = build_case("Pipeline", parent: Lucid::Case::Command) do
      step(:one) { raise Timeout::Error, "slow" }
      catch(Timeout::Error) { |ctx| failure(:timeout, error: ctx.error.message) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_match(/WARN -- : \[Lucid::Case\] Pipeline step :one raised Timeout::Error$/, output)
    assert_match(/WARN -- : \[Lucid::Case\] Pipeline caught Timeout::Error -> failure\(:timeout\)/, output)
    assert_match(/Pipeline failure\(:timeout\) content=\[:error\] in /, output)
  end

  def test_uncaught_exception_logs_raised_and_propagates
    # arrange
    @config.logging = :enabled
    klass = build_case("Explosive", parent: Lucid::Case::Command) do
      step(:one) { raise ArgumentError, "bad" }
    end

    # act
    error = assert_raises(ArgumentError) { klass.call }

    # assert
    assert_equal "bad", error.message
    assert_match(/ERROR -- : \[Lucid::Case\] Explosive raised ArgumentError$/, output)
  end

  def test_exception_message_with_sensitive_value_does_not_leak_without_values
    # arrange
    @config.logging = :enabled
    klass = build_case("Leaky", parent: Lucid::Case::Command) do
      step(:one) { raise ArgumentError, "password=hunter2" }
    end

    # act
    assert_raises(ArgumentError) { klass.call }

    # assert
    refute_includes output, "hunter2"
    assert_match(/Leaky raised ArgumentError$/, output)
  end

  def test_raising_step_with_catch_logs_messages_with_values
    # arrange
    @config.logging = :enabled
    klass = build_case("Pipeline", parent: Lucid::Case::Command) do
      logging :enabled, values: true
      step(:one) { raise Timeout::Error, "slow" }
      catch(Timeout::Error) { |ctx| failure(:timeout, error: ctx.error.message) }
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_match(/WARN -- : \[Lucid::Case\] Pipeline step :one raised Timeout::Error: slow/, output)
    assert_match(/WARN -- : \[Lucid::Case\] Pipeline caught Timeout::Error: slow -> failure\(:timeout\)/, output)
  end

  def test_uncaught_exception_logs_message_with_values
    # arrange
    @config.logging = :enabled
    klass = build_case("Explosive", parent: Lucid::Case::Command) do
      logging :enabled, values: true
      step(:one) { raise ArgumentError, "bad" }
    end

    # act
    assert_raises(ArgumentError) { klass.call }

    # assert
    assert_match(/ERROR -- : \[Lucid::Case\] Explosive raised ArgumentError: bad/, output)
  end

  def test_exception_message_is_logged_with_global_log_values
    # arrange
    @config.logging = :enabled
    @config.log_values = true
    klass = build_case("Explosive", parent: Lucid::Case::Command) do
      step(:one) { raise ArgumentError, "bad" }
    end

    # act
    assert_raises(ArgumentError) { klass.call }

    # assert
    assert_match(/Explosive raised ArgumentError: bad/, output)
  end

  def test_cache_miss_hit_and_bypass_are_logged
    # arrange
    @config.logging = :enabled
    klass = build_case("Stats", parent: Lucid::Case::Query) do
      attributes :id
      cache :enabled
      def call!
        success(id: id)
      end
    end

    # act
    klass.call(id: 1)
    klass.call(id: 1)
    klass.fresh.call(id: 1)

    # assert
    results = lines.grep(/ success /)
    assert_equal 3, results.size
    assert_match(/cache=miss in /, results[0])
    assert_match(/cache=hit in /, results[1])
    assert_match(/cache=bypass in /, results[2])
  end

  def test_no_cache_suffix_when_not_cached
    # arrange
    @config.logging = :enabled
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    refute_includes output, "cache="
  end

  def test_log_level_sets_severity_of_lines
    # arrange
    @config.logging = :enabled
    @config.log_level = :warn
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_match(/WARN -- : \[Lucid::Case\] Simple called/, output)
    refute_match(/INFO -- /, output)
  end

  def test_log_level_below_logger_threshold_is_silenced
    # arrange
    @config.logging = :enabled
    @config.log_level = :debug
    @config.logger.level = Logger::INFO
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_equal "", output
  end

  def test_log_level_debug_uses_debug_severity
    # arrange
    @config.logging = :enabled
    @config.log_level = :debug
    klass = simple_case

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_match(/DEBUG -- : \[Lucid::Case\] Simple called/, output)
  end

  def test_warn_level_still_logs_caught_exceptions
    # arrange
    @config.logging = :enabled
    @config.log_level = :error
    klass = build_case("Pipeline", parent: Lucid::Case::Command) do
      step(:one) { raise "boom" }
      catch(RuntimeError) { failure(:boom) }
    end

    # act
    klass.call

    # assert
    assert_match(/WARN -- : .*step :one raised/, output)
  end

  def test_logger_writes_prefixed_line_at_each_level
    # arrange
    @config.logging = :enabled
    %i[debug info warn error].each do |level|
      klass = build_case("Talker", parent: Lucid::Case::Command) do
        define_method(:call!) do
          logger.public_send(level, "hello")
          success
        end
      end

      # act
      klass.call
    end

    # assert
    assert_match(/DEBUG -- : \[Lucid::Case\] Talker hello/, output)
    assert_match(/INFO -- : \[Lucid::Case\] Talker hello/, output)
    assert_match(/WARN -- : \[Lucid::Case\] Talker hello/, output)
    assert_match(/ERROR -- : \[Lucid::Case\] Talker hello/, output)
  end

  def test_logger_accepts_a_block
    # arrange
    @config.logging = :enabled
    klass = build_case("Talker", parent: Lucid::Case::Command) do
      def call!
        logger.warn { "lazy #{1 + 1}" }
        success
      end
    end

    # act
    klass.call

    # assert
    assert_match(/WARN -- : \[Lucid::Case\] Talker lazy 2/, output)
  end

  def test_logger_is_silent_when_case_disabled
    # arrange
    @config.logging = :enabled
    klass = build_case("Talker", parent: Lucid::Case::Command) do
      logging :disabled
      def call!
        logger.info("hello")
        success
      end
    end

    # act
    klass.call

    # assert
    assert_equal "", output
  end

  def test_logger_is_silent_when_globally_disabled
    # arrange
    klass = build_case("Talker", parent: Lucid::Case::Command) do
      def call!
        logger.error("hello")
        success
      end
    end

    # act
    klass.call

    # assert
    assert_equal "", output
  end

  def test_logger_works_when_case_enabled_and_global_disabled
    # arrange
    klass = build_case("Talker", parent: Lucid::Case::Command) do
      logging :enabled
      def call!
        logger.info("hello")
        success
      end
    end

    # act
    klass.call

    # assert
    assert_match(/INFO -- : \[Lucid::Case\] Talker hello/, output)
  end

  def test_logger_without_configured_logger_does_not_break
    # arrange
    @config.logging = :enabled
    @config.logger = nil
    klass = build_case("Talker", parent: Lucid::Case::Command) do
      def call!
        logger.info("hello")
        logger.warn { "lazy" }
        success
      end
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal "", output
  end

  def test_case_values_true_overrides_global_false
    # arrange
    @config.filter_parameters = [:token]
    klass = simple_case { logging :enabled, values: true }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_includes output, "any"
    assert_includes output, "[FILTERED]"
    refute_includes output, "secret"
  end

  def test_case_values_false_overrides_global_true
    # arrange
    @config.log_values = true
    klass = simple_case { logging :enabled, values: false }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    refute_includes output, "secret"
    refute_includes output, "any\""
    assert_includes output, "input=[:token, :name]"
  end

  def test_case_values_true_filters_sensitive_parameters
    # arrange
    @config.filter_parameters = [:token]
    klass = simple_case { logging :enabled, values: true }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_match(/called input=.*token.*\[FILTERED\]/, output)
    refute_includes output, "secret"
  end

  def test_logging_without_values_uses_global_true
    # arrange
    @config.log_values = true
    klass = simple_case { logging :enabled }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_includes output, "secret"
  end

  def test_logging_without_values_uses_global_false
    # arrange
    klass = simple_case { logging :enabled }

    # act
    klass.call(token: "secret", name: "any")

    # assert
    refute_includes output, "secret"
    assert_includes output, "input=[:token, :name]"
  end

  def test_nil_values_does_not_alter_previous_setting
    # arrange
    klass = simple_case do
      logging :enabled, values: true
      logging :enabled, values: nil
    end

    # act
    klass.call(token: "secret", name: "any")

    # assert
    assert_includes output, "secret"
  end

  def test_subclass_inherits_values_setting
    # arrange
    parent = simple_case("Parent") { logging :enabled, values: true }
    child = build_case("Child", parent: parent)

    # act
    child.call(token: "secret", name: "any")

    # assert
    assert_includes output, "secret"
  end

  def test_subclass_overrides_values_without_changing_parent
    # arrange
    parent = simple_case("Parent") { logging :enabled, values: true }
    child = build_case("Child", parent: parent) { logging :enabled, values: false }

    # act
    child.call(token: "secret", name: "any")
    child_output = output.dup
    @io.truncate(0)
    @io.rewind
    parent.call(token: "secret", name: "any")

    # assert
    refute_includes child_output, "secret"
    assert_includes output, "secret"
  end

  def test_without_logger_does_not_break
    # arrange
    @config.logging = :enabled
    @config.logger = nil
    klass = simple_case

    # act
    result = klass.call(token: "secret", name: "any")

    # assert
    assert result.success?
    assert_equal "", output
  end
end
