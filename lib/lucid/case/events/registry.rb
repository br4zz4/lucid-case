module Lucid
  class Case
    module Events
      # Thread-safe list of Subscriptions.
      module Registry
        MUTEX = Mutex.new
        @subscriptions = [].freeze

        class << self
          # @return [Array<Lucid::Case::Events::Subscription>]
          def subscriptions
            @subscriptions
          end

          def register(subscription)
            MUTEX.synchronize { @subscriptions = (@subscriptions + [subscription]).freeze }
            subscription
          end

          def clear!
            MUTEX.synchronize { @subscriptions = [].freeze }
          end

          # @return [Array<Lucid::Case::Events::Subscription>] subscriptions that want the described Event
          def matching(kind:, name:, step:, type:, success:)
            subscriptions.select { |subscription| subscription.match?(kind: kind, name: name, step: step, type: type, success: success) }
          end
        end
      end
    end
  end
end
