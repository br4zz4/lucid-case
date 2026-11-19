module Lucid
  class Case
    # A Case that reacts to Events. Transactional like a Command, it never produces Events of its own.
    #
    # @example
    #   class Billing::OnEnrollmentApproved < Lucid::Case::Subscriber
    #     subscribe Enrollment::Approve
    #
    #     def call!
    #       Billing::StartInvoice.call(enrollment: event.content[:enrollment])
    #       success
    #     end
    #   end
    class Subscriber < Case
      kind :subscriber
      attributes :event
    end
  end
end
