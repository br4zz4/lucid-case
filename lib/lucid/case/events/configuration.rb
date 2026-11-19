module Lucid
  class Case
    module Events
      # Options under +config.events+.
      #
      # @example
      #   Lucid::Case.configure do |config|
      #     config.events.recording = :enabled
      #     config.events.retention = 7.days
      #   end
      class Configuration
        SWITCHES = %i[enabled disabled].freeze
        STORES = %i[outbox inline].freeze

        # @return [Symbol] +:disabled+ (default) or +:enabled+: whether commands record Events
        attr_reader :recording
        # @return [Symbol] +:outbox+ (default) or +:inline+
        attr_reader :store
        # @return [Symbol, #publish] +:active_job+ (default) or an object that responds to +publish(event)+
        attr_accessor :transport
        # @return [Symbol] queue of the delivery jobs
        attr_accessor :queue
        # @return [Integer] attempts of a delivery job before giving up
        attr_accessor :delivery_attempts
        # @return [String] outbox table, may be schema qualified
        attr_accessor :table_name
        # @return [String] deduplication table
        attr_accessor :deliveries_table_name
        # @return [String] ordered delivery cursors table
        attr_accessor :cursors_table_name
        # @return [ActiveSupport::Duration] how long delivered rows are kept
        attr_accessor :retention
        # @return [Symbol] +:enabled+ (default) or +:disabled+: whether +relay_pending+ purges old rows
        attr_reader :purge
        # @return [ActiveSupport::Duration] how long a relay claim holds a row
        attr_accessor :claim_timeout
        # @return [Symbol] +:disabled+ (default) or +:enabled+: skip Deliveries already made
        attr_reader :deduplication
        # @return [Array<String>] directories (relative to Rails.root) loaded at boot to register Subscribers
        attr_accessor :load_paths
        # @return [#call, nil] returns a serializable Hash captured when the Event is recorded
        attr_accessor :context
        # @return [#call, nil] +->(context, &block)+ wraps each Delivery
        attr_accessor :around_delivery

        def initialize
          @recording = :disabled
          @store = :outbox
          @transport = :active_job
          @queue = :default
          @delivery_attempts = 5
          @table_name = "lucid_case_events"
          @deliveries_table_name = "lucid_case_deliveries"
          @cursors_table_name = "lucid_case_cursors"
          @retention = 7.days
          @purge = :enabled
          @claim_timeout = 5.minutes
          @deduplication = :disabled
          @load_paths = %w[app/models]
          @context = nil
          @around_delivery = nil
        end

        def recording=(value)
          @recording = switch!(:recording, value)
        end

        def purge=(value)
          @purge = switch!(:purge, value)
        end

        def deduplication=(value)
          @deduplication = switch!(:deduplication, value)
        end

        def store=(value)
          raise ArgumentError, "store must be one of #{STORES.inspect}, got #{value.inspect}" unless STORES.include?(value)

          @store = value
        end

        # @raise [ArgumentError] when deduplication is enabled with the +:inline+ store
        def validate!
          raise ArgumentError, "deduplication requires store :outbox (the :inline store has no table)" if deduplication == :enabled && store == :inline
          raise ArgumentError, "transport must be :active_job or respond to publish(event), got #{transport.inspect}" unless transport == :active_job || transport.respond_to?(:publish)
          raise ArgumentError, "delivery_attempts must be a positive Integer, got #{delivery_attempts.inspect}" unless delivery_attempts.is_a?(Integer) && delivery_attempts.positive?

          self
        end

        private

        def switch!(name, value)
          return value if SWITCHES.include?(value)

          raise ArgumentError, "#{name} must be one of #{SWITCHES.inspect}, got #{value.inspect}"
        end
      end
    end
  end
end
