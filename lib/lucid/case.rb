require "active_support"
require "active_support/core_ext"
require "active_support/notifications"
require "active_model"
require "active_record"

require "lucid/case/version"
require "lucid/case/errors"
require "lucid/case/result"
require "lucid/case/attributes"
require "lucid/case/configuration"
require "lucid/case/validations"
require "lucid/case/kind_validator"
require "lucid/case/kinds"
require "lucid/case/transaction"
require "lucid/case/hooks"
require "lucid/case/instrumentation"
require "lucid/case/logging"
require "lucid/case/finally"
require "lucid/case/stepped"
require "lucid/case/catching"
require "lucid/case/cache"

module Lucid
  # Base class of every use case.
  #
  # Define the inputs with +attributes+ and the body with +call!+, returning
  # +success(...)+ or +failure(type, ...)+.
  #
  # @example
  #   class Users::Create < Lucid::Case
  #     attributes :params
  #
  #     def call!
  #       user = User.new(params)
  #       user.save ? success(user: user) : failure(:invalid, errors: user.errors)
  #     end
  #   end
  #
  #   Users::Create.call(params: { name: "Ana" })
  class Case
    include Attributes
    include Validations
    include Kinds
    include Transaction
    include Hooks
    include Instrumentation
    include Logging
    include Stepped
    include Catching
    include Finally
    include Cache

    class << self
      # Builds the case with +input+ and runs it.
      #
      # @return [Lucid::Case::Result]
      def call(input = {}, **keywords)
        new(input.to_h.merge(keywords)).call
      end

      # @return [Lucid::Case::Configuration]
      def configuration
        @configuration ||= Configuration.new
      end

      # Yields the global configuration.
      #
      # @yieldparam config [Lucid::Case::Configuration]
      def configure
        yield configuration
        validate_configuration!
        configuration
      end

      # Restores the default configuration.
      def reset_configuration!
        @configuration = Configuration.new
        @cache_in_use = false
      end

      # Marks that some case enabled caching, so boot validation applies. When the app has
      # already booted, validates right away (fail fast on lazily loaded classes).
      #
      # @api private
      def cache_in_use!
        @cache_in_use = true
        validate_configuration! if @booted
      end

      # Marks the app as booted (called by the Railtie).
      #
      # @api private
      def booted!
        @booted = true
      end

      # Checks the configuration when caching is in use (+config.cache = :enabled+ or a case
      # declared +cache+) and +perform_caching+ is on.
      #
      # @raise [Lucid::Case::Error::CacheStoreMissing] store is nil or a NullStore
      # @raise [Lucid::Case::Error::MissingCacheScope] +cache_scope+ is not set
      def validate_configuration!
        config = configuration
        return config unless config.perform_caching && (@cache_in_use || config.cache == :enabled)

        store = config.cache_store
        if store.nil? || store.is_a?(ActiveSupport::Cache::NullStore)
          raise Error::CacheStoreMissing, "caching is enabled but the cache store is #{store.nil? ? 'nil' : 'a NullStore'}; " \
                                          "configure Rails.cache or config.cache_store"
        end
        raise Error::MissingCacheScope, "caching is enabled but config.cache_scope is not set (use a callable or :global)" if config.cache_scope.nil?

        config
      end
    end

    # Runs the case and returns its Result.
    #
    # @return [Lucid::Case::Result]
    def call
      lucid_instrument_call do
        lucid_log_call_started
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = lucid_with_cache { lucid_run }.with_case_class(self.class)
        lucid_log_call_finished(result, started_at)
        result
      rescue StandardError => error
        lucid_log_call_raised(error)
        raise
      end
    end

    # Body of the case. Subclasses implement it.
    def call!
      raise NotImplementedError, "#{self.class.name} must implement call!"
    end

    private

    def lucid_run
      lucid_guarded { lucid_isolated { lucid_evaluate } }
    ensure
      lucid_run_finally
    end

    def lucid_isolated(&block)
      self.class.query? ? ActiveRecord::Base.while_preventing_writes(&block) : lucid_with_transaction(&block)
    end

    def lucid_evaluate
      result = valid? ? lucid_run_body : lucid_invalid_attributes_result
      lucid_ensure_result!(result)
      lucid_run_hooks(result)
      result
    end

    def lucid_ensure_result!(result)
      return if result.is_a?(Result)

      raise Error::UnexpectedResult, "#{self.class.name}#call! must return success(...) or failure(...), got #{result.inspect}"
    end

    # @return [Lucid::Case::Result] a successful result carrying +content+
    def success(**content)
      Result.new(success: true, type: :ok, content: content)
    end

    # @return [Lucid::Case::Result] a failed result of +type+ carrying +content+
    def failure(type = :error, **content)
      Result.new(success: false, type: type, content: content)
    end
  end
end

require "lucid/case/command"
require "lucid/case/query"
require "lucid/case/railtie" if defined?(Rails::Railtie)
