module Lucid
  class Case
    module Cache
      # Reads and writes results, and keeps one generation counter per case and scope.
      # Bumping the generation makes every older key unreachable without scanning the store.
      class Store
        def initialize(case_class, config = Lucid::Case.configuration)
          @case_class = case_class
          @config = config
        end

        def read(key)
          store.read(key)
        end

        def write(key, result, expires_in:)
          store.write(key, result, expires_in: expires_in)
        end

        def delete(key)
          store.delete(key)
        end

        def generation(scope)
          store.read(Key.generation_key(@case_class, scope), raw: true).to_i
        end

        def bump_generation(scope)
          key = Key.generation_key(@case_class, scope)
          store.write(key, 0, raw: true, unless_exist: true)
          store.increment(key)
        end

        def scope
          setting = @config.cache_scope
          raise Error::MissingCacheScope, "config.cache_scope is not set (use a callable or :global)" if setting.nil?
          return "global" if setting == :global

          value = setting.call
          raise Error::MissingCacheScope, "config.cache_scope returned nil" if value.nil?

          value.to_s
        end

        private

        def store
          @config.cache_store || raise(Error::CacheStoreMissing, "no cache store available for Lucid::Case caching")
        end
      end
    end
  end
end
