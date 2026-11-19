module Lucid
  class Case
    module Events
      module Transports
        # Default transport: one DeliveryJob per Subscriber that wants the Event.
        module ActiveJob
          module_function

          def publish(event)
            queue = Lucid::Case.configuration.events.queue
            Dispatcher.subscriptions_for(event).group_by(&:subscriber_id).each do |subscriber_id, subscriptions|
              if subscriptions.any?(&:ordered)
                OrderedDeliveryJob.set(queue: queue).perform_later(subscriber_id)
              else
                DeliveryJob.set(queue: queue).perform_later(event.id, subscriber_id)
              end
            end
          end
        end
      end
    end
  end
end
