module Lucid
  class Case
    # Publishes +call.lucid_case+ with +case+, +kind+, +type+ and +cache+ (:hit, :miss, :bypass or nil).
    module Instrumentation
      EVENT = "call.lucid_case".freeze

      private

      def lucid_instrument_call
        ActiveSupport::Notifications.instrument(EVENT, case: self.class, kind: self.class.kind, cache: nil) do |payload|
          @instrumentation_payload = payload
          result = yield
          payload[:type] = result.type
          result
        end
      end

      def lucid_record_cache_status(status)
        @instrumentation_payload[:cache] = status if @instrumentation_payload
      end
    end
  end
end
