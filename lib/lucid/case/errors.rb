module Lucid
  class Case
    # Base class of every error raised by Lucid::Case itself.
    class Error < StandardError
      # Raised when +call!+ (or a step) returns something that is not a Lucid::Case::Result.
      class UnexpectedResult < Error; end

      # Raised at class load time when a case defines both +call!+ and +step+.
      class AmbiguousDefinition < Error; end

      # Raised at class load time when +kind+ is unknown or redeclared with another value.
      class InvalidKind < Error; end

      # Raised at class load time when a Query declares transaction or hooks.
      class SideEffectInQuery < Error; end

      # Raised at class load time when a Command declares +cache+.
      class CacheOnCommand < Error; end

      # Raised when a cached Query receives an input that cannot produce a stable cache key.
      class UncacheableInput < Error; end

      # Raised at boot when caching is on and the effective cache store is nil or a NullStore.
      class CacheStoreMissing < Error; end

      # Raised at boot when caching is on and +cache_scope+ was not configured.
      class MissingCacheScope < Error; end
    end
  end
end
