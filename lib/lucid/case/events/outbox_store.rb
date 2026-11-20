module Lucid
  class Case
    module Events
      # @api private
      #
      # Writes Events to the outbox table in the current transaction and relays them after the commit.
      module OutboxStore
        module_function

        def record(event, log: false)
          Record.insert_event!(event)
          ActiveRecord.after_all_transactions_commit { Relay.relay([event.id], log: log) }
        end
      end
    end
  end
end
