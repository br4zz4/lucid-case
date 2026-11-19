require "test_helper"

class EventsInlineTest < EventsTest
  def approve_command
    build_command("Enrollment::Approve") do
      attributes :enrollment
      define_method(:call!) { success(enrollment: enrollment) }
    end
  end

  def test_subscriber_class_receives_event_with_reloaded_record
    # arrange
    target = approve_command
    received = []
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        received << event
        success
      end
    end
    order = Order.create!(status: "pending")

    # act
    target.call(enrollment: order)

    # assert
    event = received.first
    assert_equal 1, received.size
    assert_kind_of Lucid::Case::Event, event
    assert_equal order, event.content[:enrollment]
    assert_equal "enrollment.approve", event.name
    assert_equal :ok, event.type
  end

  def test_default_subscription_ignores_failure
    # arrange
    target = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    received = []
    build_subscriber("Billing::OnCharged") do
      subscribe target
      define_method(:call!) do
        received << event
        success
      end
    end

    # act
    target.call

    # assert
    assert_empty received
  end

  def test_on_filters_for_failure
    # arrange
    target = build_command("Payment::Charge") { define_method(:call!) { failure(:card_declined) } }
    called = []
    {
      "Billing::Default" => {},
      "Billing::OnFailure" => { on: :failure },
      "Billing::OnAny" => { on: :any },
      "Billing::OnDeclined" => { on: :card_declined },
      "Billing::OnTimeout" => { on: :timeout }
    }.each do |name, options|
      build_subscriber(name) do
        subscribe target, **options
        define_method(:call!) do
          called << self.class.name
          success
        end
      end
    end

    # act
    target.call

    # assert
    assert_equal %w[Billing::OnAny Billing::OnDeclined Billing::OnFailure], called.sort
  end

  def test_multiple_subscribe_distinguished_by_name
    # arrange
    approve = approve_command
    reject = build_command("Enrollment::Reject") { define_method(:call!) { failure(:rejected) } }
    emitter = build_command("Enrollment::Notify") do
      define_method(:call!) do
        emit(:credit_limit_reached)
        success
      end
    end
    names = []
    build_subscriber("Billing::OnEnrollment") do
      subscribe approve
      subscribe reject, on: :any
      subscribe :credit_limit_reached
      define_method(:call!) do
        names << event.name
        success
      end
    end

    # act
    approve.call(enrollment: Order.create!(status: "a"))
    reject.call
    emitter.call

    # assert
    assert_equal %w[credit_limit_reached enrollment.approve enrollment.reject], names.sort
  end

  def test_transactional_subscriber_calls_command_which_records_its_own_event
    # arrange
    target = approve_command
    invoice = build_command("Billing::StartInvoice") do
      define_method(:call!) { success(order: Order.create!(status: "invoice")) }
    end
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        invoice.call
        success
      end
    end
    spy(invoice, as: :invoice_spy)
    spy(target, as: :target_spy)

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal ["billing.start_invoice", "enrollment.approve"], events.map(&:name).sort
    assert_equal 2, Order.count
  end

  def test_subscriber_records_no_event_of_its_own
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) { success }
    end
    spy(target)

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal ["enrollment.approve"], events.map(&:name)
  end

  def test_external_subscription_and_global_block
    # arrange
    target = approve_command
    called = []
    subscriber = build_subscriber("Billing::OnApproved") do
      define_method(:call!) do
        called << :class
        success
      end
    end
    subscriber.subscribe(target)
    Lucid::Case.subscribe(target, as: :guardian_mailer) { |_event| called << :block }

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal %i[block class], called.sort
  end

  def test_failing_subscriber_does_not_stop_others_and_error_is_reraised
    # arrange
    target = approve_command
    called = []
    Lucid::Case.subscribe(target, as: :first) { |_event| called << :first }
    Lucid::Case.subscribe(target, as: :broken) { |_event| raise "broken" }
    Lucid::Case.subscribe(target, as: :last) { |_event| called << :last }
    order = Order.create!(status: "a")

    # act
    error = assert_raises(RuntimeError) { target.call(enrollment: order) }

    # assert
    assert_equal "broken", error.message
    assert_equal %i[first last], called.sort
    assert_equal 1, Order.count
  end

  def test_first_error_is_the_one_reraised
    # arrange
    target = approve_command
    Lucid::Case.subscribe(target, as: :a) { |_event| raise ArgumentError, "first" }
    Lucid::Case.subscribe(target, as: :b) { |_event| raise TypeError, "second" }

    # act / assert
    error = assert_raises(ArgumentError, TypeError) { target.call(enrollment: Order.create!(status: "a")) }
    assert_equal "first", error.message
  end

  def test_subscriber_case_returning_failure_is_only_a_finished_delivery
    # arrange
    target = approve_command
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) { failure(:not_billable) }
    end

    # act
    result = target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert result.success?
  end

  def test_context_is_captured_in_the_event
    # arrange
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }
    target = approve_command
    spy(target)

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal({ tenant: "alfa" }, events.first.context)
  end

  def test_around_delivery_wraps_subscriber
    # arrange
    Lucid::Case.configuration.events.context = -> { { tenant: "alfa" } }
    Lucid::Case.configuration.events.around_delivery = lambda do |context, &block|
      Thread.current[:lucid_test_tenant] = context[:tenant]
      block.call
    end
    target = approve_command
    seen = nil
    Lucid::Case.subscribe(target, as: :tenant_spy) { |_event| seen = Thread.current[:lucid_test_tenant] }

    # act
    target.call(enrollment: Order.create!(status: "a"))

    # assert
    assert_equal "alfa", seen
  end

  def test_payload_symbol_keys_are_preserved
    # arrange
    target = build_command("Payment::Charge") { define_method(:call!) { success(amount: { cents: 100 }, tags: %i[a b]) } }
    spy(target)

    # act
    target.call

    # assert
    assert_equal({ cents: 100 }, events.first.content[:amount])
    assert_equal %i[a b], events.first.content[:tags]
  end

  def test_outer_rollback_runs_no_subscriber_class
    # arrange
    target = approve_command
    called = []
    build_subscriber("Billing::OnApproved") do
      subscribe target
      define_method(:call!) do
        called << event
        success
      end
    end
    order = Order.create!(status: "a")

    # act
    ActiveRecord::Base.transaction do
      target.call(enrollment: order)
      raise ActiveRecord::Rollback
    end

    # assert
    assert_empty called
  end
end
