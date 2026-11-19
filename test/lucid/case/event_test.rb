require "test_helper"
require "json"

class EventTest < Minitest::Test
  def build_event(**overrides)
    Lucid::Case::Event.new(
      **{
        id: "0b6c6d52-6a1c-4c53-9b21-7b2f6f6f1a11",
        kind: :case,
        name: "enrollment.approve",
        source: "Enrollment::Approve",
        step: nil,
        type: :ok,
        success: true,
        input: { enrollment_id: 1 },
        content: { approved: true },
        context: { tenant: "alfa" },
        occurred_at: Time.utc(2026, 11, 19, 12, 0, 0)
      }.merge(overrides)
    )
  end

  def test_readers
    # arrange
    event = build_event(step: :start)

    # act
    values = [event.id, event.kind, event.name, event.source, event.step, event.type]

    # assert
    assert_equal ["0b6c6d52-6a1c-4c53-9b21-7b2f6f6f1a11", :case, "enrollment.approve", "Enrollment::Approve", :start, :ok], values
    assert_equal({ enrollment_id: 1 }, event.input)
    assert_equal({ approved: true }, event.content)
    assert_equal({ tenant: "alfa" }, event.context)
    assert_equal Time.utc(2026, 11, 19, 12, 0, 0), event.occurred_at
  end

  def test_optional_fields_default
    # arrange
    event = Lucid::Case::Event.new(id: "x", kind: :custom, name: "n", source: "S", occurred_at: Time.now)

    # assert
    assert_nil event.step
    assert_nil event.type
    assert event.success?
    assert_equal({}, event.input)
    assert_equal({}, event.content)
    assert_equal({}, event.context)
  end

  def test_success_predicate
    # arrange
    ok = build_event(success: true)
    failed = build_event(success: false, type: :card_declined)

    # assert
    assert ok.success?
    refute failed.success?
  end

  def test_event_is_frozen
    # arrange
    event = build_event

    # assert
    assert event.frozen?
  end

  def test_to_h_has_symbol_keys
    # arrange
    event = build_event

    # act
    hash = event.to_h

    # assert
    assert_kind_of Hash, hash
    assert hash.keys.all?(Symbol)
    assert_equal "enrollment.approve", hash[:name]
    assert_equal "0b6c6d52-6a1c-4c53-9b21-7b2f6f6f1a11", hash[:id]
  end

  def test_to_h_is_json_serializable
    # arrange
    hash = build_event.to_h

    # act
    json = JSON.generate(hash)

    # assert
    assert_kind_of String, json
    assert_kind_of Hash, JSON.parse(json)
  end

  def test_from_h_round_trip
    # arrange
    event = build_event(step: :start)

    # act
    rebuilt = Lucid::Case::Event.from_h(event.to_h)

    # assert
    assert_equal event, rebuilt
    assert_kind_of Lucid::Case::Event, rebuilt
  end

  def test_from_h_round_trip_through_json
    # arrange
    event = build_event(success: false, type: :card_declined)

    # act
    rebuilt = Lucid::Case::Event.from_h(JSON.parse(JSON.generate(event.to_h)))

    # assert
    assert_equal event, rebuilt
  end

  def test_from_h_accepts_string_keys
    # arrange
    hash = build_event.to_h.transform_keys(&:to_s)

    # act
    rebuilt = Lucid::Case::Event.from_h(hash)

    # assert
    assert_equal build_event, rebuilt
  end

  def test_different_events_are_not_equal
    # arrange
    a = build_event
    b = build_event(name: "enrollment.reject")

    # assert
    refute_equal a, b
  end
end
