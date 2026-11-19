module Lucid
  class Case
    module Events
      # Position of an ordered subscriber in the outbox: the id of the last row it processed.
      class Cursor < ActiveRecord::Base
        self.inheritance_column = nil
        self.record_timestamps = false

        class << self
          def table_name
            configured = Lucid::Case.configuration.events.cursors_table_name
            if @table_name != configured && !@switching_table
              @switching_table = true
              begin
                self.table_name = configured
              ensure
                @switching_table = false
              end
            end
            @table_name || configured
          end

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
