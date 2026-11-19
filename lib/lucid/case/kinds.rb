module Lucid
  class Case
    # A case is either a Command (writes, may run in a transaction and fire hooks)
    # or a Query (read-only, cacheable). Declare it with +kind+ or by inheriting from
    # Lucid::Case::Command / Lucid::Case::Query.
    module Kinds
      KINDS = %i[command query].freeze

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :case_kind, instance_accessor: false, instance_predicate: false, default: :command
        base.class_attribute :kind_locked, instance_accessor: false, instance_predicate: false, default: false
        base.class_attribute :side_effects_declared, instance_accessor: false, instance_predicate: false, default: false
      end

      module ClassMethods
        # Declares the kind (+:command+ or +:query+), or returns it when called without arguments.
        #
        # @raise [Lucid::Case::Error::InvalidKind] unknown kind, or redeclared with another value
        # @raise [Lucid::Case::Error::SideEffectInQuery] +:query+ after transaction or hooks were declared
        def kind(value = nil)
          return case_kind if value.nil?

          raise Error::InvalidKind, "unknown kind #{value.inspect}, use one of #{KINDS.inspect}" unless KINDS.include?(value)
          raise Error::InvalidKind, "#{name} is #{case_kind}, it cannot be redeclared as #{value}" if kind_locked && value != case_kind

          if value == :query && side_effects_declared
            raise Error::SideEffectInQuery, "#{name} declares transaction or hooks and cannot be a query"
          end

          self.case_kind = value
          self.kind_locked = true
        end

        def command?
          case_kind == :command
        end

        def query?
          case_kind == :query
        end

        # @api private
        def declare_side_effect!(macro)
          raise Error::SideEffectInQuery, "#{name || 'a query'} is a query and cannot declare #{macro}" if query?

          self.side_effects_declared = true
        end
      end
    end
  end
end
