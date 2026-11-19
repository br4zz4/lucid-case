module Lucid
  class Case
    module Events
      # Test support: captures Events at recording time, without persisting or delivering them.
      module Recorder
        KEY = :lucid_case_event_captures

        module_function

        # @return [Array<Lucid::Case::Event>] the Events recorded inside the block, in order
        def capture
          scope = []
          stack.push(scope)
          begin
            yield
          ensure
            stack.pop
          end
          scope
        end

        def capturing?
          !stack.empty?
        end

        def record(event)
          stack.each { |scope| scope << event }
        end

        # @return [Array<Lucid::Case::Event>] events that match +target+ and the given filters
        def matching(events, target, type: nil, content: nil, input: nil, step: nil)
          kind, name = describe(target, step)
          events.select do |event|
            event.kind == kind && event.name == name && event.step == step&.to_sym &&
              (type.nil? || event.type == type.to_sym) &&
              subset?(content, event.content) && subset?(input, event.input)
          end
        end

        def describe(target, step)
          case target
          when Class then [step ? :step : :case, Events.event_name(target)]
          else [:custom, target.to_s]
          end
        end

        def subset?(expected, actual)
          expected.nil? || expected.all? { |key, value| actual.key?(key) && actual[key] == value }
        end

        def stack
          Thread.current[KEY] ||= []
        end
        private_class_method :stack
      end
    end
  end
end
