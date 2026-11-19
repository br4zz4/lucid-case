require "test_helper"

class EventsOutboxPendingTest < EventsTest
  def test_outbox_store_with_recording_raises_not_implemented_on_success
    # arrange
    with_events(store: :outbox)
    command = build_command("Enrollment::Approve") { define_method(:call!) { success } }

    # act / assert
    error = assert_raises(NotImplementedError) { command.call }
    assert_includes error.message, ":outbox"
  end

  def test_outbox_store_with_recording_raises_not_implemented_on_failure
    # arrange
    with_events(store: :outbox)
    command = build_command("Enrollment::Approve") { define_method(:call!) { failure(:nope) } }

    # act / assert
    error = assert_raises(NotImplementedError) { command.call }
    assert_includes error.message, ":outbox"
  end
end
