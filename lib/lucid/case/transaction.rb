module Lucid
  class Case
    # Wraps Commands in a database transaction (with savepoint) by default.
    # A failure rolls back and returns the result; an exception rolls back and propagates.
    module Transaction
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :transaction_setting, instance_accessor: false, instance_predicate: false, default: nil
      end

      module ClassMethods
        # Turns the transaction on or off for this case, overriding +config.transaction+.
        #
        # @param value [Symbol] +:enabled+ or +:disabled+
        def transaction(value)
          Configuration.switch!(:transaction, value)
          declare_side_effect!("transaction")
          self.transaction_setting = value
        end

        # @return [Boolean] whether this case runs inside a transaction
        def transactional?
          (command? || subscriber?) && (transaction_setting || Lucid::Case.configuration.transaction) == :enabled
        end
      end

      private

      def lucid_with_transaction
        return yield unless self.class.transactional?

        result = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          result = yield
          raise ActiveRecord::Rollback if result.failure?
        end
        result
      end
    end
  end
end
