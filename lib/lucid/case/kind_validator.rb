module Lucid
  class Case
    # Validates that an attribute is an instance of one of the given classes.
    #
    # @example
    #   validates :params, presence: true, kind: Hash
    #   validates :id, kind: [Integer, String]
    class KindValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        return if kinds.any? { |kind| value.is_a?(kind) }

        record.errors.add(attribute, options[:message] || "must be a kind of #{kinds.join(', ')}")
      end

      private

      def kinds
        @kinds ||= Array(options[:with] || options[:in])
      end
    end
  end
end
