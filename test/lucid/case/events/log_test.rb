require "test_helper"

class EventsLogTest < EventsTest
  UUID = "\\h{8}-\\h{4}-\\h{4}-\\h{4}-\\h{12}".freeze

  def charge_command(logging: :enabled, &block)
    build_command("Payment::Charge") do
      logging logging
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
      class_eval(&block) if block
    end
  end

  def test_logs_custom_and_case_events_with_logging_enabled
    # arrange
    command = charge_command

    # act
    command.call

    # assert
    assert_match(/\[Lucid::Case\] Payment::Charge event "credit_limit_reached" recorded id=#{UUID}/, log.string)
    assert_match(/event "payment.charge" recorded id=#{UUID}/, log.string)
  end

  def test_logs_one_line_per_recorded_event
    # arrange
    command = charge_command

    # act
    command.call

    # assert
    assert_equal 2, log.string.lines.count { |line| line.include?(" recorded id=") }
  end

  def test_logged_id_matches_the_event_id
    # arrange
    command = charge_command
    spy(command)

    # act
    command.call

    # assert
    assert_includes log.string, %(event "payment.charge" recorded id=#{events.first.id})
  end

  def test_logs_step_event
    # arrange
    command = build_command("Order::Place") do
      logging :enabled
      step(:reserve_stock) { continue }
      step(:charge_card) { success }
    end
    spy(command, step: :reserve_stock)

    # act
    command.call

    # assert
    assert_match(/event "order.place" step :reserve_stock recorded id=#{UUID}/, log.string)
  end

  def test_logs_warn_when_events_are_kept_after_raise_without_transaction
    # arrange
    command = build_command("Provisioning::Run") do
      logging :enabled
      transaction :disabled
      step(:start) { continue }
      step(:configure_dns) { raise "dns down" }
    end
    spy(command, step: :start)

    # act
    assert_raises(RuntimeError) { command.call }

    # assert
    assert_match(/WARN.*events kept after raise \(no transaction\): "provisioning.run" step :start id=#{UUID}/, log.string)
  end

  def test_logs_error_when_payload_is_not_serializable_without_transaction
    # arrange
    command = build_command("Payment::Charge") do
      logging :enabled
      transaction :disabled
      define_method(:call!) { success(callback: -> {}) }
    end

    # act
    assert_raises(Lucid::Case::Error::UnserializableEvent) { command.call }

    # assert
    assert_match(/ERROR.*event "payment.charge" not recorded: payload not serializable; data already persisted/, log.string)
  end

  def test_logging_disabled_writes_no_event_lines_on_success
    # arrange
    command = charge_command(logging: :disabled)

    # act
    command.call

    # assert
    assert_empty event_log_lines
  end

  def test_logging_disabled_writes_no_step_or_kept_lines
    # arrange
    command = build_command("Provisioning::Run") do
      logging :disabled
      transaction :disabled
      step(:start) { continue }
      step(:configure_dns) { raise "dns down" }
    end
    spy(command, step: :start)

    # act
    assert_raises(RuntimeError) { command.call }

    # assert
    assert_empty event_log_lines
  end

  def test_logging_disabled_writes_no_not_recorded_line
    # arrange
    command = build_command("Payment::Charge") do
      logging :disabled
      transaction :disabled
      define_method(:call!) { success(callback: -> {}) }
    end

    # act
    assert_raises(Lucid::Case::Error::UnserializableEvent) { command.call }

    # assert
    assert_empty event_log_lines
  end

  def test_no_event_lines_when_recording_is_off
    # arrange
    with_events(recording: :disabled)
    command = charge_command

    # act
    command.call

    # assert
    assert_empty event_log_lines
  end
end
