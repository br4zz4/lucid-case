module Lucid
  class Case
    # Global defaults, set in +config/initializers/lucid_case.rb+.
    #
    # @example
    #   Lucid::Case.configure do |config|
    #     config.transaction = :enabled
    #     config.cache = :disabled
    #     config.accumulate = :enabled
    #     config.logging = :disabled
    #     config.cache_duration = 5.minutes
    #     config.cache_scope = -> { Tenant.current }
    #   end
    class Configuration
      SWITCHES = %i[enabled disabled].freeze
      LOG_LEVELS = %i[debug info warn error].freeze

      # @return [Symbol] +:enabled+ (default) or +:disabled+: whether Commands run in a transaction
      attr_reader :transaction
      # @return [Symbol] +:disabled+ (default) or +:enabled+: whether Queries are cached
      attr_reader :cache
      # @return [Symbol] +:enabled+ (default) or +:disabled+: whether steps accumulate the content of +continue+
      attr_reader :accumulate
      # @return [Symbol] +:disabled+ (default) or +:enabled+: whether cases log their calls, steps and results
      attr_reader :logging
      # @return [Symbol] level used for the log lines (+:debug+, +:info+ (default), +:warn+, +:error+)
      attr_reader :log_level
      # @return [Boolean] log input and content values (filtered by +filter_parameters+) instead of only their keys (default: false)
      attr_accessor :log_values
      # @return [Array] parameter filters for logged values (default: the app's +filter_parameters+)
      attr_writer :filter_parameters
      # @return [ActiveSupport::Duration] default cache lifetime
      attr_accessor :cache_duration
      # @return [ActiveSupport::Cache::Store, nil] store used for Query caching (default: +Rails.cache+)
      attr_writer :cache_store
      # @return [Proc, Symbol, nil] a callable returning the cache scope, or +:global+
      attr_accessor :cache_scope
      # @return [Boolean] master switch for caching (default: the app's +perform_caching+)
      attr_writer :perform_caching

      # @return [Lucid::Case::Events::Configuration]
      attr_reader :events

      def initialize
        @events = Events::Configuration.new
        @transaction = :enabled
        @cache = :disabled
        @accumulate = :enabled
        @logging = :disabled
        @log_level = :info
        @log_values = false
        @filter_parameters = nil
        @logger = nil
        @cache_duration = 5.minutes
        @cache_store = nil
        @cache_scope = nil
        @perform_caching = nil
      end

      def transaction=(value)
        @transaction = self.class.switch!(:transaction, value)
      end

      def accumulate=(value)
        @accumulate = self.class.switch!(:accumulate, value)
      end

      def logging=(value)
        @logging = self.class.switch!(:logging, value)
      end

      def log_level=(value)
        raise ArgumentError, "log_level must be one of #{LOG_LEVELS.inspect}, got #{value.inspect}" unless LOG_LEVELS.include?(value)

        @log_level = value
      end

      # @return [Logger, nil] logger for the log lines (default: +Rails.logger+)
      def logger
        @logger || (defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil)
      end

      attr_writer :logger

      # @return [ActiveSupport::ParameterFilter]
      def parameter_filter
        filters = @filter_parameters
        filters ||= defined?(Rails) && Rails.respond_to?(:application) && Rails.application ? Rails.application.config.filter_parameters : []
        ActiveSupport::ParameterFilter.new(filters)
      end

      def cache=(value)
        @cache = self.class.switch!(:cache, value)
      end

      def cache_store
        @cache_store || (defined?(Rails) && Rails.respond_to?(:cache) ? Rails.cache : nil)
      end

      def perform_caching
        return @perform_caching unless @perform_caching.nil?

        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.config.action_controller.perform_caching ? true : false
        else
          true
        end
      end

      def self.switch!(name, value)
        return value if SWITCHES.include?(value)

        raise ArgumentError, "#{name} must be one of #{SWITCHES.inspect}, got #{value.inspect}"
      end
    end
  end
end
