require "digest"
require "json"
require "bigdecimal"

module Lucid
  class Case
    module Cache
      # Builds a stable cache key from a case's inputs.
      #
      # ActiveRecord objects contribute +cache_key_with_version+, hashes are sorted recursively,
      # and anything that cannot be represented stably raises UncacheableInput.
      class Key
        SEPARATOR = "/".freeze

        def initialize(case_class:, version:, scope:, generation:, inputs:)
          @case_class = case_class
          @version = version
          @scope = scope
          @generation = generation
          @inputs = inputs
        end

        def to_s
          ["lucid_case", @case_class.name, "v#{@version}", @scope, "g#{@generation}", digest].join(SEPARATOR)
        end

        def self.generation_key(case_class, scope)
          ["lucid_case", case_class.name, scope, "generation"].join(SEPARATOR)
        end

        private

        def digest
          Digest::SHA256.hexdigest(JSON.generate(normalize(@inputs, "inputs")))
        end

        def normalize(value, path)
          case value
          when nil then [:nil]
          when true, false then [:bool, value]
          when Symbol then [:sym, value.to_s]
          when String then [:str, value]
          when Integer, Float, BigDecimal then [:num, value.to_s]
          when Time, DateTime then [:time, value.utc.iso8601(6)]
          when Date then [:date, value.iso8601]
          when Hash then normalize_hash(value, path)
          when Array then [:arr, value.each_with_index.map { |item, index| normalize(item, "#{path}[#{index}]") }]
          else normalize_object(value, path)
          end
        end

        def normalize_hash(hash, path)
          pairs = hash.map { |key, item| [key.to_s, item] }.sort_by(&:first).map do |key, item|
            [key, normalize(item, "#{path}.#{key}")]
          end
          [:hash, pairs]
        end

        def normalize_object(value, path)
          return [:record, value.cache_key_with_version.to_s] if value.respond_to?(:cache_key_with_version)
          return normalize_hash(value.to_unsafe_h, path) if value.respond_to?(:to_unsafe_h)

          raise Error::UncacheableInput, "#{@case_class.name} cannot cache #{path} of type #{value.class}"
        end
      end
    end
  end
end
