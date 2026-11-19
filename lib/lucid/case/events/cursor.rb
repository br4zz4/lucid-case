module Lucid
  class Case
    module Events
      # Position of an ordered subscriber in the outbox: the id of the last row it processed.
      class Cursor < ActiveRecord::Base
        self.inheritance_column = nil
        self.record_timestamps = false

        extend ConfiguredTable
        configured_table :cursors_table_name

        class << self
          # @return [Cursor] the cursor of +subscriber_id+, created at position 0 when missing
          def for(subscriber_id)
            find_by(subscriber: subscriber_id) || create!(subscriber: subscriber_id, last_event_id: 0)
          rescue ActiveRecord::RecordNotUnique
            find_by!(subscriber: subscriber_id)
          end
        end
      end
    end
  end
end
