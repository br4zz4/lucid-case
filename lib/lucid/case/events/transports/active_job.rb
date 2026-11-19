module Lucid
  class Case
    module Events
      module Transports
        # Default transport: one DeliveryJob per Subscriber that wants the Event.
        module ActiveJob
          module_function

          def publish(event)
            Dispatcher.subscriptions_for(event).uniq(&:subscriber_id).each do |subscription|
              DeliveryJob.set(queue: Lucid::Case.configuration.events.queue).perform_later(event.id, subscription.subscriber_id)
            end
          end
        end
      end
    end
  end
end
