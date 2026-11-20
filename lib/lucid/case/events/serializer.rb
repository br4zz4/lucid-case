module Lucid
  class Case
    module Events
      # @api private
      #
      # Turns input, content and context into values that survive storage and job arguments
      # (ActiveJob::Arguments: records become GlobalIDs and come back reloaded).
      module Serializer
        module_function

        # @return [Array(Object, Object, Object)] +input+, +content+ and +context+ after a serialization round trip
        # @raise [ActiveJob::SerializationError] when a value cannot be serialized
        def round_trip(input, content, context)
          ActiveJob::Arguments.deserialize(dump(input, content, context))
        end

        # @return [Array] serialized form, safe to store as JSON
        def dump(input, content, context)
          ActiveJob::Arguments.serialize([normalize(input), normalize(content), normalize(context)])
        end

        # @return [Object] +value+ with ActiveModel::Errors and ActionController::Parameters turned into Hashes
        def normalize(value)
          case value
          when ActiveModel::Errors then value.to_hash
          when ->(item) { item.respond_to?(:to_unsafe_h) } then normalize(value.to_unsafe_h)
          when Hash then value.transform_values { |item| normalize(item) }
          when Array then value.map { |item| normalize(item) }
          else value
          end
        end
      end
    end
  end
end
