require "lucid/case/cache/key"
require "lucid/case/cache/store"
require "lucid/case/cache/invocation"

module Lucid
  class Case
    # Opt-in result caching for Queries, keyed by the case inputs.
    #
    #   cache :enabled
    #   cache :disabled
    #   cache duration: 5.minutes
    #   cache :enabled, duration: 10.minutes
    #   cache version: 2
    #
    # Only successful results are cached. On a hit nothing of the case runs.
    module Cache
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :cache_setting, instance_accessor: false, instance_predicate: false, default: nil
        base.class_attribute :cache_duration_setting, instance_accessor: false, instance_predicate: false, default: nil
        base.class_attribute :cache_version_setting, instance_accessor: false, instance_predicate: false, default: 1
      end

      module ClassMethods
        # Configures caching for this Query.
        #
        # @param mode [Symbol, nil] +:enabled+ or +:disabled+
        # @param duration [ActiveSupport::Duration, nil] cache lifetime (implies +:enabled+ when mode is omitted)
        # @param version [Integer, nil] bump to invalidate every entry of this case on deploy
        # @raise [Lucid::Case::Error::CacheOnCommand] when the case is not a query
        def cache(mode = nil, duration: nil, version: nil)
          unless query?
            raise Error::CacheOnCommand, "#{name || 'a case'} is a #{kind}: declare `kind :query` (or inherit from Lucid::Case::Query) before `cache`"
          end

          mode = :enabled if mode.nil? && duration
          self.cache_setting = Configuration.switch!(:cache, mode) if mode
          self.cache_duration_setting = duration if duration
          self.cache_version_setting = version if version
          Lucid::Case.cache_in_use! if cache_setting == :enabled
        end

        # @return [Boolean] whether results of this case are cached right now
        def caching_enabled?
          config = Lucid::Case.configuration
          query? && config.perform_caching && (cache_setting || config.cache) == :enabled
        end

        # @return [ActiveSupport::Duration]
        def cache_lifetime
          cache_duration_setting || Lucid::Case.configuration.cache_duration
        end

        # Returns an object whose +call+ ignores the cache, runs the query and stores the new result.
        def fresh
          lucid_ensure_query!(:fresh)
          Cache::Invocation.new(self)
        end

        # Marks cached results as stale, so the next +call+ runs the query again.
        #
        # - With inputs (+stale(period: period)+), only the entry for those inputs.
        # - With attribute names (+stale(:period)+), every entry of this case in the current
        #   scope: something about that attribute changed. The cache keeps no per-attribute
        #   index, so this may drop a bit more than strictly needed, never less.
        # - Without arguments, every entry of this case in the current scope.
        #
        # @example
        #   Reports::Revenue.stale(period: period)
        #   Reports::Revenue.stale(:period)
        #   Reports::Revenue.stale
        #
        # @return [Boolean] whether something was invalidated (always +true+ when more than one entry may be affected)
        # @raise [ArgumentError] a symbol that is not an attribute of the case, or symbols mixed with inputs
        def stale(*names, **inputs)
          lucid_ensure_query!(:stale)
          store = Cache::Store.new(self)
          if names.any?
            raise ArgumentError, "stale takes attribute names or inputs, not both" if inputs.any?

            unknown = names.map(&:to_sym) - attribute_names
            raise ArgumentError, "#{name} has no attribute #{unknown.map(&:inspect).join(', ')}" if unknown.any?

            return lucid_stale_all(store)
          end
          return lucid_stale_all(store) if inputs.empty?

          key = new(inputs).send(:lucid_cache_key, store)
          existed = !store.read(key).nil?
          store.delete(key)
          existed
        end

        private

        def lucid_stale_all(store)
          store.bump_generation(store.scope)
          true
        end

        def lucid_ensure_query!(method_name)
          raise NoMethodError, "#{name}.#{method_name} is only available on queries (kind :query)" unless query?
        end
      end

      # @api private
      def lucid_refresh!
        @refresh = true
        self
      end

      private

      def lucid_cache_key(store)
        scope = store.scope
        Cache::Key.new(case_class: self.class, version: self.class.cache_version_setting, scope: scope,
                       generation: store.generation(scope), inputs: attribute_values).to_s
      end

      def lucid_with_cache
        return yield unless self.class.caching_enabled?

        store = Cache::Store.new(self.class)
        key = lucid_cache_key(store)
        unless @refresh
          hit = store.read(key)
          if hit
            lucid_record_cache_status(:hit)
            return hit
          end
        end

        result = yield
        lucid_record_cache_status(@refresh ? :bypass : :miss)
        lucid_write_cache(store, key, result) if result.success?
        result
      end

      def lucid_write_cache(store, key, result)
        now = Time.current
        lifetime = self.class.cache_lifetime
        store.write(key, result.lucid_with_cache(cached_at: now, expires_at: now + lifetime), expires_in: lifetime)
      end
    end
  end
end
