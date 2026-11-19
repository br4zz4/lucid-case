module Lucid
  class Case
    module Events
      # +subscribe+: inside a Subscriber it registers the class; on +Lucid::Case+ itself it registers a block.
      #
      # @example
      #   class Billing::OnApproved < Lucid::Case::Subscriber
      #     subscribe Enrollment::Approve
      #     subscribe Enrollment::Reject, on: :any
      #     subscribe :credit_limit_reached
      #   end
      #
      #   Lucid::Case.subscribe(Enrollment::Approve, as: :guardian_mailer) { |event| ... }
      module Subscribing
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # @param target [Class, Symbol, String] a Command class (Case or Step event) or a Custom event name
          # @param on [Symbol, Array<Symbol>, nil] +:success+ (default), +:failure+, +:any+ or failure types
          # @param step [Symbol, nil] subscribe to a step of the Command
          # @param ordered [Boolean] deliver in order, one at a time
          # @param as [Symbol, String, nil] identity of a block subscription
          #
          # @raise [Lucid::Case::Error::SubscribeOutsideSubscriber] in a Command or Query
          # @raise [Lucid::Case::Error::InvalidSubscription] on an invalid target, step or +on+
          def subscribe(target, on: nil, step: nil, ordered: false, as: nil, &block)
            if equal?(Lucid::Case)
              raise ArgumentError, "Lucid::Case.subscribe needs a block" unless block

              lucid_register_subscription(target, on: on, step: step, ordered: ordered, subscriber_id: as, handler: block, global: true)
            else
              unless subscriber?
                raise Error::SubscribeOutsideSubscriber, "#{name || 'a case'} is a #{kind}: subscribe is only available in Lucid::Case::Subscriber"
              end
              raise ArgumentError, "subscribe in a Subscriber takes no block" if block

              lucid_register_subscription(target, on: on, step: step, ordered: ordered, subscriber_id: name, handler: self, global: false)
            end
          end

          private

          def lucid_register_subscription(target, on:, step:, ordered:, subscriber_id:, handler:, global:)
            kind, target_name = lucid_resolve_target(target, step)
            on = lucid_resolve_on(kind, on)
            subscriber_id = lucid_resolve_subscriber_id(subscriber_id, ordered, global)
            Registry.register(
              Subscription.new(target_name: target_name, kind: kind, step: step&.to_sym, on: on, ordered: ordered ? true : false,
                               subscriber_id: subscriber_id, handler: handler)
            )
          end

          def lucid_resolve_target(target, step)
            case target
            when Symbol, String
              raise Error::InvalidSubscription, "step: is only for Command targets" if step

              [:custom, target.to_s]
            when Class
              lucid_resolve_class_target(target, step)
            else
              raise Error::InvalidSubscription, "cannot subscribe to #{target.inspect}"
            end
          end

          def lucid_resolve_class_target(target, step)
            unless target < Lucid::Case && target.command?
              raise Error::InvalidSubscription, "#{target.name || target.inspect} is not a Command: only Commands produce events"
            end
            return [:case, Events.event_name(target)] unless step
            unless target.step_definitions.any? { |name, _| name == step.to_sym }
              raise Error::InvalidSubscription, "#{target.name} has no step #{step.inspect}"
            end

            [:step, Events.event_name(target)]
          end

          def lucid_resolve_on(kind, on)
            return :success if on.nil? && kind == :custom
            raise Error::InvalidSubscription, "on: does not apply to a Custom event" if kind == :custom
            return :success if on.nil?

            values = Array(on)
            raise Error::InvalidSubscription, "on: needs Symbols, got #{on.inspect}" if values.empty? || !values.all?(Symbol)

            on
          end

          def lucid_resolve_subscriber_id(subscriber_id, ordered, global)
            if subscriber_id.nil?
              needs_identity = global && (ordered || Lucid::Case.configuration.events.deduplication == :enabled)
              raise Error::InvalidSubscription, "a block subscription needs as: when ordered or with deduplication enabled" if needs_identity
              raise Error::InvalidSubscription, "an anonymous Subscriber class cannot subscribe" unless global
            end

            subscriber_id&.to_s || "block:#{SecureRandom.hex(4)}"
          end
        end
      end

      # @return [String] +"enrollment.approve"+ for +Enrollment::Approve+
      def self.event_name(klass)
        klass.name.underscore.tr("/", ".")
      end
    end
  end
end
