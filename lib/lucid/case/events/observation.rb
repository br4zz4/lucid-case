module Lucid
  class Case
    module Events
      # Synchronous observers of the events a Command produces: called where the event is born,
      # inside the transaction of a success and after the rollback of a failure, whether or not
      # events are being recorded.
      module Observation
        module_function

        # @param event [Lucid::Case::Event]
        # @param command [Lucid::Case] the Command instance that produced +event+
        # @param result [Lucid::Case::Result, Object, nil] the result (or step outcome) behind +event+
        def notify(event:, command:, result:)
          Lucid::Case.configuration.events.observers.each do |observer|
            observer.call(event: event, command: command, result: result)
          end
        end

        def observed?
          Lucid::Case.configuration.events.observers.any?
        end
      end
    end
  end
end
