module Lucid
  class Case
    module Events
      # Wording of the event log lines (written through the case logging switch).
      module Log
        module_function

        def label(event)
          "event #{event.name.inspect}#{event.step ? " step #{event.step.inspect}" : ''}"
        end

        def recorded(event)
          "#{label(event)} recorded id=#{event.id}"
        end

        def kept_after_raise(events)
          "events kept after raise (no transaction): #{events.map { |event| "#{label(event).delete_prefix('event ')} id=#{event.id}" }.join(', ')}"
        end

        def not_recorded(name)
          "event #{name.inspect} not recorded: payload not serializable; data already persisted"
        end
      end
    end
  end
end
