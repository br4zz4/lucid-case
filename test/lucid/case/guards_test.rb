require "test_helper"

class GuardsTest < Minitest::Test
  def setup
    User.delete_all
    Lucid::Case.reset_configuration!
    @previous_locale = I18n.locale
    @previous_available = I18n.available_locales
    I18n.available_locales = [*@previous_available, :en, :"pt-BR"].uniq
    I18n.locale = :en
    I18n.backend.reload!
  end

  def teardown
    I18n.locale = @previous_locale
    I18n.available_locales = @previous_available
    I18n.backend.reload!
    Lucid::Case.reset_configuration!
    User.delete_all
  end

  def translate(locale = :en, **tree)
    I18n.backend.store_translations(locale, tree)
  end

  def command(name = "ClassEnrollment::Create", &block)
    build_case(name, parent: Lucid::Case::Command, &block)
  end

  def test_method_guard_fails_with_type_and_translated_message
    # arrange
    translate(class_enrollment: { create: { class_full: "Turma está com capacidade máxima" } })
    klass = command do
      fail_if :class_full?
      def class_full? = true
      def call! = raise("body must not run")
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :class_full, result.type
    assert_equal ["Turma está com capacidade máxima"], result[:errors]
  end

  def test_method_guard_does_not_execute_body
    # arrange
    klass = command do
      class << self
        attr_accessor :executed
      end
      fail_if :class_full?
      def class_full? = true

      def call!
        self.class.executed = true
        success
      end
    end

    # act
    klass.call

    # assert
    refute klass.executed
  end

  def test_false_guard_lets_body_run
    # arrange
    klass = command do
      fail_if :class_full?
      def class_full? = false
      def call! = success(done: true)
    end

    # act
    result = klass.call

    # assert
    assert result.success?
    assert_equal true, result[:done]
  end

  def test_fail_fast_in_declaration_order
    # arrange
    klass = command do
      attributes :calls
      fail_if :a?
      fail_if :b?
      def a? = (calls << :a) && true
      def b? = (calls << :b) && true
    end
    calls = []

    # act
    result = klass.call(calls: calls)

    # assert
    assert_equal :a, result.type
    assert_equal [:a], calls
  end

  def test_later_guard_runs_when_earlier_is_false
    # arrange
    klass = command do
      fail_if :a?
      fail_if :b?
      def a? = false
      def b? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal :b, result.type
  end

  def test_truthy_non_boolean_value_triggers_guard
    # arrange
    klass = command do
      fail_if :a?
      def a? = "x"
    end

    # act
    result = klass.call

    # assert
    assert result.failure?
    assert_equal :a, result.type
  end

  def test_nil_guard_does_not_trigger
    # arrange
    klass = command do
      fail_if :a?
      def a? = nil
      def call! = success
    end

    # act
    result = klass.call

    # assert
    assert result.success?
  end

  def test_invalid_attributes_come_before_guards
    # arrange
    klass = command do
      attributes :params, :calls
      validates :params, presence: true
      fail_if :a?
      def a? = (calls << :a) && true
    end
    calls = []

    # act
    result = klass.call(params: nil, calls: calls)

    # assert
    assert_equal :invalid_attributes, result.type
    assert_empty calls
  end

  def test_custom_type_with_as_looks_up_message_by_new_type
    # arrange
    translate(class_enrollment: { create: { duplicate: "Já matriculado", already_enrolled: "errado" } })
    klass = command do
      fail_if :already_enrolled?, as: :duplicate
      def already_enrolled? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal :duplicate, result.type
    assert_equal ["Já matriculado"], result[:errors]
  end

  def test_string_message_is_used_without_consulting_i18n
    # arrange
    translate(class_enrollment: { create: { in_use: "do yml" } })
    klass = command do
      fail_if :in_use?, message: "Template em uso"
      def in_use? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal :in_use, result.type
    assert_equal ["Template em uso"], result[:errors]
  end

  def test_symbol_message_is_explicit_i18n_key
    # arrange
    translate(outra: { chave: "X" })
    klass = command do
      fail_if :in_use?, message: :"outra.chave"
      def in_use? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal ["X"], result[:errors]
  end

  def test_cascade_level_one_uses_case_scoped_key
    # arrange
    translate(foo: { bar: { class_full: "Do caso" } }, lucid_case: { failures: { class_full: "Global" } })
    klass = command("Foo::Bar") do
      fail_if :class_full?
      def class_full? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal ["Do caso"], result[:errors]
  end

  def test_cascade_level_two_uses_lucid_case_failures
    # arrange
    translate(lucid_case: { failures: { class_full: "Cheio" } })
    klass = command("Foo::Bar") do
      fail_if :class_full?
      def class_full? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal ["Cheio"], result[:errors]
  end

  def test_cascade_level_three_humanizes_type
    # arrange
    klass = command("Foo::Bar") do
      fail_if :class_full?
      def class_full? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal ["Class full"], result[:errors]
  end

  def test_anonymous_case_starts_at_lucid_case_failures
    # arrange
    translate(lucid_case: { failures: { a: "Global A" } })
    klass = Class.new(Lucid::Case) do
      fail_if :a?
      def a? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal :a, result.type
    assert_equal ["Global A"], result[:errors]
  end

  def test_anonymous_case_falls_back_to_humanized_type
    # arrange
    klass = Class.new(Lucid::Case) do
      fail_if :not_retryable?
      def not_retryable? = true
    end

    # act
    result = klass.call

    # assert
    assert_equal ["Not retryable"], result[:errors]
  end

  def test_message_uses_current_locale
    # arrange
    translate(:en, foo: { bar: { class_full: "Full" } })
    translate(:"pt-BR", foo: { bar: { class_full: "Cheia" } })
    klass = command("Foo::Bar") do
      fail_if :class_full?
      def class_full? = true
    end

    # act
    english = I18n.with_locale(:en) { klass.call }
    portuguese = I18n.with_locale(:"pt-BR") { klass.call }

    # assert
    assert_equal ["Full"], english[:errors]
    assert_equal ["Cheia"], portuguese[:errors]
  end

  def test_with_single_method_adds_content
    # arrange
    translate(class_enrollment: { create: { not_retryable: "Não pode" } })
    klass = command do
      attributes :provisioning
      fail_if :not_retryable?, with: :provisioning
      def not_retryable? = true
    end

    # act
    result = klass.call(provisioning: :the_provisioning)

    # assert
    assert_equal :not_retryable, result.type
    assert_equal({ errors: ["Não pode"], provisioning: :the_provisioning }, result.content)
  end

  def test_with_multiple_methods_includes_private
    # arrange
    klass = command do
      fail_if :a?, with: %i[resource event]
      def a? = true
      def resource = :res

      private

      def event = :evt
    end

    # act
    result = klass.call

    # assert
    assert_equal %i[errors resource event].sort, result.content.keys.sort
    assert_equal :res, result[:resource]
    assert_equal :evt, result[:event]
  end

  def test_with_is_only_evaluated_when_guard_fires
    # arrange
    klass = command do
      attributes :calls
      fail_if :a?, with: :expensive
      def a? = false
      def expensive = (calls << :expensive)
      def call! = success
    end
    calls = []

    # act
    result = klass.call(calls: calls)

    # assert
    assert result.success?
    assert_empty calls
  end

  def test_block_form_runs_with_case_as_self_and_uses_cascade
    # arrange
    translate(class_enrollment: { create: { class_full: "Cheia" } })
    klass = command do
      attributes :seen
      fail_if(:class_full) { (seen << self) && school_class.full? }
      def school_class = Struct.new(:full?).new(true)
    end
    seen = []

    # act
    result = klass.call(seen: seen)

    # assert
    assert_equal :class_full, result.type
    assert_equal ["Cheia"], result[:errors]
    assert_equal 1, seen.size
    assert_kind_of klass, seen.first
  end

  def test_block_form_false_lets_body_run
    # arrange
    klass = command do
      fail_if(:class_full) { false }
      def call! = success(done: true)
    end

    # act
    result = klass.call

    # assert
    assert result.success?
  end

  def test_block_form_accepts_with_and_message
    # arrange
    klass = command do
      fail_if(:class_full, with: :school_class, message: "x") { true }
      def school_class = :klass
    end

    # act
    result = klass.call

    # assert
    assert_equal :class_full, result.type
    assert_equal({ errors: ["x"], school_class: :klass }, result.content)
  end

  def test_fail_with_in_body_uses_cascade_and_content
    # arrange
    translate(class_enrollment: { create: { nothing_to_do: "Nada a fazer" } })
    klass = command do
      def call! = fail_with(:nothing_to_do, plan: [])
    end

    # act
    result = klass.call

    # assert
    assert_equal :nothing_to_do, result.type
    assert_equal({ errors: ["Nada a fazer"], plan: [] }, result.content)
  end

  def test_fail_with_message_option
    # arrange
    klass = command do
      def call! = fail_with(:x, message: "y")
    end

    # act
    result = klass.call

    # assert
    assert_equal :x, result.type
    assert_equal ["y"], result[:errors]
  end

  def test_inheritance_runs_parent_guards_first_and_does_not_leak
    # arrange
    parent = command("Parent") do
      attributes :calls
      fail_if :a?
      def a? = (calls << :a) && false
      def b? = (calls << :b) && false
      def call! = success
    end
    child = build_case("Child", parent: parent) { fail_if :b? }
    parent_calls = []
    child_calls = []

    # act
    child.call(calls: child_calls)
    parent.call(calls: parent_calls)

    # assert
    assert_equal %i[a b], child_calls
    assert_equal [:a], parent_calls
  end

  def test_guards_run_before_steps
    # arrange
    klass = command do
      attributes :calls
      fail_if :a?
      def a? = true
      step(:primeiro) { calls << :primeiro }
    end
    calls = []

    # act
    result = klass.call(calls: calls)

    # assert
    assert_equal :a, result.type
    assert_empty calls
  end

  def test_guard_in_query_runs_with_writes_prevented_and_fails
    # arrange
    klass = build_case("Dashboard::Report", parent: Lucid::Case::Query) do
      attributes :seen
      fail_if :a?
      def a? = (seen << ActiveRecord::Base.connection.preventing_writes?) && true
    end
    seen = []

    # act
    result = klass.call(seen: seen)

    # assert
    assert result.failure?
    assert_equal :a, result.type
    assert_equal [true], seen
  end

  def test_predicate_exception_goes_to_catch
    # arrange
    klass = command do
      fail_if :a?
      def a? = raise(ActiveRecord::RecordNotFound, "nope")

      catch(ActiveRecord::RecordNotFound) { |ctx| failure(:not_found, errors: [ctx.error.message]) }
    end

    # act
    result = klass.call

    # assert
    assert_equal :not_found, result.type
    assert_equal ["nope"], result[:errors]
  end

  def test_predicate_exception_without_catch_propagates
    # arrange
    klass = command do
      fail_if :a?
      def a? = raise(ActiveRecord::RecordNotFound, "nope")
    end

    # act / assert
    assert_raises(ActiveRecord::RecordNotFound) { klass.call }
  end

  def test_guard_failure_rolls_back_and_runs_after_failure_but_not_after_commit
    # arrange
    klass = command do
      attributes :calls
      after_failure { calls << :after_failure }
      after_commit { calls << :after_commit }
      fail_if :a?
      def a? = User.create!(name: "Ana") && true
    end
    calls = []

    # act
    result = klass.call(calls: calls)

    # assert
    assert_equal :a, result.type
    assert_equal 0, User.count
    assert_equal [:after_failure], calls
  end

  def test_logs_guard_with_method_name
    # arrange
    io = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(io)
    klass = command do
      logging :enabled
      fail_if :class_full?
      def class_full? = true
    end

    # act
    klass.call

    # assert
    assert_includes io.string,
                    "[Lucid::Case] ClassEnrollment::Create guard :class_full? -> failure(:class_full) content=[:errors]"
  end

  def test_logs_guard_with_type_for_block_form
    # arrange
    io = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(io)
    klass = command do
      logging :enabled
      fail_if(:class_full) { true }
    end

    # act
    klass.call

    # assert
    assert_includes io.string,
                    "[Lucid::Case] ClassEnrollment::Create guard :class_full -> failure(:class_full) content=[:errors]"
  end

  def test_fail_if_without_name_raises
    # act / assert
    assert_raises(ArgumentError) { command { fail_if } }
    assert_raises(ArgumentError) { command { fail_if { true } } }
  end

  def test_block_with_question_mark_type_raises
    # act / assert
    assert_raises(ArgumentError) { command { fail_if(:class_full?) { true } } }
  end

  def test_as_with_block_raises
    # act / assert
    assert_raises(ArgumentError) { command { fail_if(:x, as: :y) { true } } }
  end

  def test_invalid_with_raises
    # act / assert
    assert_raises(ArgumentError) { command { fail_if :a?, with: "x" } }
    assert_raises(ArgumentError) { command { fail_if :a?, with: [1] } }
  end

  def test_with_errors_raises
    # act / assert
    assert_raises(ArgumentError) { command { fail_if :a?, with: :errors } }
    assert_raises(ArgumentError) { command { fail_if :a?, with: %i[resource errors] } }
  end

  def test_fail_with_errors_content_raises
    # arrange
    klass = command do
      def call! = fail_with(:x, errors: [])
    end

    # act / assert
    assert_raises(ArgumentError) { klass.call }
  end

  def test_missing_predicate_raises_no_method_error_on_call
    # arrange
    klass = command { fail_if :nao_existe? }

    # act / assert
    assert_raises(NoMethodError) { klass.call }
  end

  def test_missing_with_method_raises_no_method_error_when_guard_fires
    # arrange
    klass = command do
      fail_if :a?, with: :nao_existe
      def a? = true
    end

    # act / assert
    assert_raises(NoMethodError) { klass.call }
  end
end

class GuardsEventsTest < EventsTest
  def setup
    super
    I18n.backend.reload!
  end

  def teardown
    I18n.backend.reload!
    super
  end

  def test_guard_failure_records_case_failure_event_with_guard_type
    # arrange
    command = build_command("ClassEnrollment::Create") do
      fail_if :class_full?
      def class_full? = User.create!(name: "Ana") && true
    end
    spy(command, on: :any)

    # act
    command.call

    # assert
    event = events.first
    assert_equal 1, events.size
    assert_equal :case, event.kind
    assert_equal :class_full, event.type
    refute event.success?
    assert_equal 0, User.count
  end

  def test_guard_failure_with_outbox_stores_result_type
    # arrange
    with_events(store: :outbox)
    Lucid::Case.configuration.events.table_name = "lucid_case_events"
    Lucid::Case::Events::Record.reset_column_information
    Lucid::Case::Events::Record.delete_all
    command = build_command("ClassEnrollment::Create") do
      fail_if :class_full?
      def class_full? = true
    end

    # act
    command.call

    # assert
    record = Lucid::Case::Events::Record.order(:id).last
    assert_equal "class_full", record.result_type
    refute record.success
  ensure
    Lucid::Case::Events::Record.delete_all
  end
end
