require "test_helper"

class InstrumentationTest < Minitest::Test
  def capture(&block)
    events = []
    ActiveSupport::Notifications.subscribed(->(event) { events << event }, "call.lucid_case", &block)
    events
  end

  def test_command_success
    # arrange
    klass = build_case("Users::Create", parent: Lucid::Case::Command) { def call! = success }

    # act
    events = capture { klass.call }

    # assert
    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal klass, payload[:case]
    assert_equal :command, payload[:kind]
    assert_equal :ok, payload[:type]
    assert payload.key?(:cache)
    assert_nil payload[:cache]
    assert_operator events.first.duration, :>, 0
  end

  def test_query_kind
    # arrange
    klass = build_case("Report", parent: Lucid::Case::Query) { def call! = success }

    # act
    events = capture { klass.call }

    # assert
    assert_equal :query, events.first.payload[:kind]
    assert_equal klass, events.first.payload[:case]
    assert_nil events.first.payload[:cache]
  end

  def test_failure_type
    # arrange
    klass = build_case("Users::Create", parent: Lucid::Case::Command) { def call! = failure(:not_found) }

    # act
    events = capture { klass.call }

    # assert
    assert_equal 1, events.size
    assert_equal :not_found, events.first.payload[:type]
    assert_operator events.first.duration, :>, 0
  end

  def test_kind_declared_directly
    # arrange
    klass = build_case("Report") do
      kind :query
      def call! = success
    end

    # act
    events = capture { klass.call }

    # assert
    assert_equal :query, events.first.payload[:kind]
  end

  def test_one_event_per_call
    # arrange
    klass = build_case("Users::Create", parent: Lucid::Case::Command) { def call! = success }

    # act
    events = capture do
      klass.call
      klass.call
    end

    # assert
    assert_equal 2, events.size
  end

  def test_exception_still_publishes_event
    # arrange
    klass = build_case("Users::Create", parent: Lucid::Case::Command) { def call! = raise("boom") }

    # act
    events = capture { assert_raises(RuntimeError) { klass.call } }

    # assert
    assert_equal 1, events.size
    assert_equal klass, events.first.payload[:case]
  end
end
