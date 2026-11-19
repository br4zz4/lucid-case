module Lucid
  class Case
    # Declares the inputs of a case. State is kept per class with copy-on-write, so
    # subclasses never leak definitions into their parents or siblings, and values
    # live only in the instance.
    module Attributes
      UNSET = Object.new.freeze

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :attribute_definitions, instance_accessor: false, instance_predicate: false, default: {}.freeze
      end

      module ClassMethods
        # Declares inputs. Unknown keys passed to +call+ are ignored.
        #
        # @example
        #   attributes :params, :user
        #   attributes :limit, default: 10
        def attributes(*names, default: UNSET)
          names.each { |name| attribute(name, default: default) }
        end

        # Declares one input, optionally with a default (a value or a callable).
        def attribute(name, default: UNSET)
          name = name.to_sym
          self.attribute_definitions = attribute_definitions.merge(name => default).freeze
          define_method(name) { @attribute_values[name] } unless method_defined?(name)
        end

        # @return [Array<Symbol>]
        def attribute_names
          attribute_definitions.keys
        end
      end

      def initialize(input = {})
        input = input.to_h.symbolize_keys
        @attribute_values = self.class.attribute_definitions.each_with_object({}) do |(name, default), values|
          values[name] = if input.key?(name)
                           input[name]
                         elsif default.equal?(UNSET)
                           nil
                         else
                           default.respond_to?(:call) ? default.call : default.dup
                         end
        end
      end

      # @return [Hash{Symbol => Object}]
      def attribute_values
        @attribute_values
      end
    end
  end
end
