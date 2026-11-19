require "lucid/case"

module Lucid
  class Case
    # Assertions for the Events a block of code records. Include it in a Minitest or ActiveSupport::TestCase.
    #
    # Events are captured when they are recorded: nothing is persisted or delivered, no table is needed, and it
    # works inside transactional tests. Commands record while capturing even with +recording = :disabled+,
    # unless they declare +events :disabled+.
    #
    # @example
    #   require "lucid/case/test_helpers"
    #
    #   class EnrollmentApproveTest < ActiveSupport::TestCase
    #     include Lucid::Case::TestHelpers
    #
    #     test "emits" do
    #       assert_event(Enrollment::Approve, type: :ok, content: { enrollment: enrollment }) { Enrollment::Approve.call(enrollment: enrollment) }
    #     end
    #   end
    module TestHelpers
      # @return [Array<Lucid::Case::Event>]
      def capture_events(&block)
        Events::Recorder.capture(&block)
      end

      # Passes when some Event recorded in the block matches. +content+ and +input+ match as subsets.
      #
      # @param target [Class, Symbol, String] a Command class (Case event; with +step:+ a Step event) or a Custom event name
      # @return [Lucid::Case::Event] the first matching Event
      def assert_event(target, type: nil, content: nil, input: nil, step: nil, &block)
        events = capture_events(&block)
        found = Events::Recorder.matching(events, target, type: type, content: content, input: input, step: step)
        assert found.any?, "expected an event #{target.inspect} (type: #{type.inspect}, content: #{content.inspect}); recorded: #{lucid_event_names(events)}"
        found.first
      end

      # Passes when no Event recorded in the block matches.
      def assert_no_event(target, type: nil, content: nil, input: nil, step: nil, &block)
        events = capture_events(&block)
        found = Events::Recorder.matching(events, target, type: type, content: content, input: input, step: step)
        assert found.empty?, "expected no event #{target.inspect}, but recorded: #{lucid_event_names(found)}"
      end

      private

      def lucid_event_names(events)
        events.empty? ? "none" : events.map { |event| "#{event.name}#{event.step ? ":#{event.step}" : ''}(#{event.type.inspect})" }.join(", ")
      end
    end
  end
end
