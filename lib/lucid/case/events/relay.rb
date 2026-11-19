module Lucid
  class Case
    module Events
      # Hands Events from the outbox to the transport.
      module Relay
        module_function

        # Claims the rows (so concurrent relays never take the same one), publishes each to the transport and
        # marks it delivered. A failing transport releases the claim and never raises.
        #
        # @return [Array<String>] uuids whose transport failed
        def relay(uuids, log: false)
          uuids = Array(uuids)
          return [] if uuids.empty?

          token = SecureRandom.uuid
          now = Time.current
          Record.relayable(now).where(uuid: uuids).update_all(claimed_at: now, claim_token: token)
          Record.where(uuid: uuids, claim_token: token).order(:id).filter_map { |row| publish(row, token, log) }
        end

        def publish(row, token, log)
          event = row.to_event
          Lucid::Case::Events.transport.publish(event)
          Record.where(id: row.id, claim_token: token).update_all(delivered_at: Time.current)
          nil
        rescue StandardError => error
          Record.where(id: row.id, claim_token: token).update_all(claimed_at: nil, claim_token: nil)
          Log.emit(log, "#{Log.label(event || row)} id=#{row.uuid} relay failed: #{error.class}")
          row.uuid
        end
        private_class_method :publish
      end
    end
  end
end
