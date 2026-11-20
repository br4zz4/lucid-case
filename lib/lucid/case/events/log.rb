module Lucid
  class Case
    module Events
      # Wording of the event log lines (written through the case logging switch).
      #
      # @api private
      module Log
        module_function

        def label(event)
          "event #{event.name.inspect}#{event.step.present? ? " step #{event.step.to_sym.inspect}" : ''}"
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

        # @return [Boolean] whether the Subscriber (class or block handler) logs
        def enabled_for(handler)
          handler.is_a?(Class) && handler.respond_to?(:logging?) ? handler.logging? : Lucid::Case.configuration.logging == :enabled
        end

        # Writes +message+ through the configured logger when +enabled+.
        def emit(enabled, message, level: :error)
          return unless enabled

          logger = Lucid::Case.configuration.logger
          logger&.public_send(level) { "#{Lucid::Case::Logging::PREFIX} #{message}" }
        end
      end
    end
  end
end
