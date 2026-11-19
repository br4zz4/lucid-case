module Lucid
  class Case
    module Cache
      # Invalidates a Query's cache when an Event happens, in the publisher's process right after the commit.
      module StaleOn
        # Declares that +target+ invalidates this Query.
        #
        # Without a mapping it calls +stale+ (everything in the current scope). With one, each value is a
        # callable that receives the Event and returns the input to invalidate: +stale_on X, period: ->(e) { e.content[:period] }+
        # calls +stale(period: ...)+, so the mapping must cover the attributes the entry was cached with.
        #
        # @param target [Class, Symbol, String] a Command class (Case or Step event) or a Custom event name
        # @param on [Symbol, Array<Symbol>, nil] same values as +subscribe+
        # @param step [Symbol, nil] a step of the Command
        # @raise [Lucid::Case::Error::InvalidSubscription] outside a Query or with an invalid target, step or +on+
        def stale_on(target, on: nil, step: nil, **mapping)
          raise Error::InvalidSubscription, "#{name || 'a case'} is a #{kind}: stale_on is only available on queries" unless query?

          kind, target_name = lucid_resolve_target(target, step)
          on = lucid_resolve_on(kind, on)
          query = self
          handler = lambda do |event|
            mapping.empty? ? query.stale : query.stale(**mapping.transform_values { |callable| callable.call(event) })
          end
          Events::Registry.register(
            Events::Subscription.new(target_name: target_name, kind: kind, step: step&.to_sym, on: on, ordered: false,
                                     subscriber_id: "stale_on:#{name}", handler: handler, in_process: true)
          )
        end
      end
    end
  end
end
