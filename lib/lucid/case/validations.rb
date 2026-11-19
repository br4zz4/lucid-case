module Lucid
  class Case
    # ActiveModel validations over the case attributes. When invalid, the case body
    # does not run and the result is +failure(:invalid_attributes, errors: ...)+.
    module Validations
      INVALID_ATTRIBUTES = :invalid_attributes

      def self.included(base)
        base.include ActiveModel::Validations
        base.extend ClassMethods
      end

      module ClassMethods
        def model_name
          @model_name ||= ActiveModel::Name.new(self, nil, name || "LucidCase")
        end
      end

      private

      def lucid_invalid_attributes_result
        failure(INVALID_ATTRIBUTES, errors: errors)
      end
    end
  end
end
