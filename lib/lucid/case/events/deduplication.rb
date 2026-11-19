module Lucid
  class Case
    module Events
      # Row that marks a Delivery already made.
      class DeliveryRecord < ActiveRecord::Base
        self.inheritance_column = nil
        self.record_timestamps = false

        class << self
          def table_name
            configured = Lucid::Case.configuration.events.deliveries_table_name
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
        end
      end

      # Skips Deliveries already made when +config.events.deduplication+ is enabled.
      #
      # A transactional Subscriber marks inside its own transaction, so a failure undoes the mark. A block or a
      # Subscriber without transaction marks first and removes the mark when it raises, so the retry runs again.
      module Deduplication
        module_function

        def enabled?
          Lucid::Case.configuration.events.deduplication == :enabled
        end

        # @return [Boolean] whether the block ran (false when the Delivery was already made)
        def once(event, subscription, &block)
          transactional?(subscription) ? within_transaction(event, subscription, &block) : mark_then_run(event, subscription, &block)
        end

        def transactional?(subscription)
          handler = subscription.handler
          handler.is_a?(Class) && handler.respond_to?(:transactional?) && handler.transactional?
        end

        def mark(event, subscription)
          ActiveRecord::Base.transaction(requires_new: true) do
            DeliveryRecord.create!(event_uuid: event.id, subscriber: subscription.subscriber_id, created_at: Time.current)
          end
          true
        rescue ActiveRecord::RecordNotUnique
          false
        end

        def within_transaction(event, subscription)
          ran = false
          ActiveRecord::Base.transaction(requires_new: true) do
            next unless mark(event, subscription)

            yield
            ran = true
          end
          ran
        end

        def mark_then_run(event, subscription)
          return false unless mark(event, subscription)

          begin
            yield
            true
          rescue StandardError
            DeliveryRecord.where(event_uuid: event.id, subscriber: subscription.subscriber_id).delete_all
            raise
          end
        end
      end
    end
  end
end
