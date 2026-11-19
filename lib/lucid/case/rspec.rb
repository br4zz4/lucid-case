require "lucid/case"

module Lucid
  class Case
    # RSpec matchers for the Events a block records. +require "lucid/case/rspec"+ includes them in every example group.
    #
    # @example
    #   expect { Enrollment::Approve.call(enrollment: enrollment) }
    #     .to emit_event(Enrollment::Approve).with(type: :ok, content: { enrollment: enrollment })
    module RSpecMatchers
      class EmitEvent
        def initialize(target)
          @target = target
          @filters = {}
        end

        def with(**filters)
          @filters = filters
          self
        end

        def supports_block_expectations?
          true
        end

        def matches?(block)
          @events = Events::Recorder.capture(&block)
          @found = Events::Recorder.matching(@events, @target, **@filters)
          @found.any?
        end

        def does_not_match?(block)
          !matches?(block)
        end

        def description
          "emit event #{@target.inspect}#{@filters.empty? ? '' : " with #{@filters.inspect}"}"
        end

        def failure_message
          "expected the block to #{description}, but recorded: #{names(@events)}"
        end

        def failure_message_when_negated
          "expected the block not to #{description}, but recorded: #{names(@found)}"
        end

        private

        def names(events)
          events.empty? ? "none" : events.map { |event| "#{event.name}#{event.step ? ":#{event.step}" : ''}(#{event.type.inspect})" }.join(", ")
        end
      end

      def emit_event(target)
        EmitEvent.new(target)
      end
    end
  end
end

RSpec.configure { |config| config.include Lucid::Case::RSpecMatchers } if defined?(RSpec.configure)
