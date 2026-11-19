module Lucid
  class Case
    module Events
      # Delivers one Event to one Subscriber, retrying on error up to +config.events.delivery_attempts+ executions.
      class DeliveryJob < ::ActiveJob::Base
        def perform(event_uuid, subscriber_id)
          row = Record.find_by(uuid: event_uuid)
          return log_purged(event_uuid, subscriber_id) unless row

          event = row.to_event
          subscription = Dispatcher.subscriptions_for(event).find { |item| item.subscriber_id == subscriber_id }
          return unless subscription

          deliver_with_retry(subscription, event)
        end

        private

        def deliver_with_retry(subscription, event)
          if Deduplication.enabled?
            Deduplication.once(event, subscription) { Dispatcher.deliver(subscription, event) }
          else
            Dispatcher.deliver(subscription, event)
          end
        rescue StandardError => error
          return retry_job(wait: 0) if executions < Lucid::Case.configuration.events.delivery_attempts

          Log.emit(Log.enabled_for(subscription.handler),
                   "#{Log.label(event)} id=#{event.id} delivery to #{subscription.subscriber_id} gave up after #{executions} attempts: #{error.class}")
          raise
        end

        def log_purged(event_uuid, subscriber_id)
          handler = Registry.subscriptions.find { |item| item.subscriber_id == subscriber_id }&.handler
          Log.emit(Log.enabled_for(handler), "event id=#{event_uuid} not found (purged) for #{subscriber_id}")
        end
      end
    end
  end
end
