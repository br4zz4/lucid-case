module Lucid
  class Case
    module Events
      # Row of the outbox table.
      class Record < ActiveRecord::Base
        self.abstract_class = false
        self.inheritance_column = nil
        self.record_timestamps = false

        extend ConfiguredTable
        configured_table :table_name

        class << self
          def relayable(now = Time.current)
            where(delivered_at: nil).where("claimed_at IS NULL OR claimed_at < ?", now - Lucid::Case.configuration.events.claim_timeout)
          end
        end

        # @return [Lucid::Case::Event]
        def to_event
          input, content = ActiveJob::Arguments.deserialize(payload)
          Event.new(id: uuid, kind: kind, name: name, source: source, step: step, type: result_type, success: success,
                    input: input, content: content, context: (context || {}).deep_symbolize_keys, occurred_at: occurred_at)
        end

        # @return [Lucid::Case::Events::Record] the inserted row
        def self.insert_event!(event)
          input, content = Serializer.dump(event.input, event.content, {})
          create!(uuid: event.id, kind: event.kind.to_s, name: event.name, source: event.source, step: event.step&.to_s,
                  result_type: event.type&.to_s, success: event.success?, payload: [input, content],
                  context: event.context.as_json, occurred_at: event.occurred_at, created_at: Time.current)
        end
      end
    end
  end
end
