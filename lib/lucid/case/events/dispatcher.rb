module Lucid
  class Case
    module Events
      # Runs the Subscribers that match an Event.
      #
      # @api private
      module Dispatcher
        module_function

        # Delivers +event+ to every matching subscription. A failing Subscriber does not stop the others;
        # the first error is raised after all of them ran.
        def dispatch(event)
          errors = []
          subscriptions_for(event).each do |subscription|
            deliver(subscription, event)
          rescue StandardError => error
            errors << error
          end
          raise errors.first if errors.any?
        end

        def subscriptions_for(event)
          Registry.matching(kind: event.kind, name: event.name, step: event.step, type: event.type, success: event.success?)
        end

        # Runs one Delivery inside +around_delivery+.
        def deliver(subscription, event)
          handler = subscription.handler
          invoke = -> { handler.is_a?(Class) ? handler.call(event: event) : handler.call(event) }
          around = Lucid::Case.configuration.events.around_delivery
          around ? around.call(event.context, &invoke) : invoke.call
        end
      end
    end
  end
end
