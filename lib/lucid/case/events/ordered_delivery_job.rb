module Lucid
  class Case
    module Events
      # Delivers the events of the ordered subscriptions of one Subscriber, one at a time and in recording order.
      #
      # Each event runs in its own transaction holding a lock on the subscriber's cursor, and the cursor moves after
      # each success. The first error stops the run and the job retries from the event that failed.
      class OrderedDeliveryJob < ::ActiveJob::Base
        def perform(subscriber_id)
          nil while step(subscriber_id)
        rescue StandardError => error
          return retry_job(wait: ((executions**4) + 2).seconds) if executions < Lucid::Case.configuration.events.delivery_attempts

          handler = Registry.subscriptions.find { |item| item.subscriber_id == subscriber_id }&.handler
          Log.emit(Log.enabled_for(handler), "ordered delivery to #{subscriber_id} gave up after #{executions} attempts: #{error.class}")
          raise
        end

        private

        def step(subscriber_id)
          subscriptions = Registry.subscriptions.select { |item| item.ordered && item.subscriber_id == subscriber_id }
          return false if subscriptions.empty?

          cursor = Cursor.for(subscriber_id)
          Cursor.transaction do
            cursor.lock!
            row, subscription = next_row(cursor, subscriptions)
            return false unless row

            event = row.to_event
            deliver(subscription, event)
            cursor.update!(last_event_id: row.id)
            true
          end
        end

        def next_row(cursor, subscriptions)
          candidates = Events.rows_for(subscriptions).where("id > ?", cursor.last_event_id).order(:id)
          candidates.each do |row|
            subscription = subscriptions.find do |item|
              item.match?(kind: row.kind.to_sym, name: row.name, step: row.step&.to_sym, type: row.result_type, success: row.success)
            end
            return [row, subscription] if subscription
          end
          nil
        end

        def deliver(subscription, event)
          return Dispatcher.deliver(subscription, event) unless Deduplication.enabled?

          Deduplication.once(event, subscription) { Dispatcher.deliver(subscription, event) }
        end
      end
    end
  end
end
