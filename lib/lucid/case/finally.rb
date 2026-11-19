module Lucid
  class Case
    # Cleanup that always runs after the case, whether it succeeded, failed or raised.
    #
    # Blocks run in declaration order, after the transaction is closed and after +catch+
    # handlers, so the result is already decided. They are not run when a cached result is
    # served. An exception raised by a +finally+ block propagates.
    #
    # @example
    #   finally(:release_lock) { lock.release }
    module Finally
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :finally_blocks, instance_accessor: false, instance_predicate: false, default: [].freeze
      end

      module ClassMethods
        # Registers a block that always runs when the case ends.
        #
        # @param name [Symbol, nil] a label used in the log
        def finally(name = nil, &block)
          raise ArgumentError, "finally needs a block" unless block

          self.finally_blocks = (finally_blocks + [[name, block]]).freeze
        end
      end

      private

      def lucid_run_finally
        self.class.finally_blocks.each do |name, block|
          lucid_log("finally#{name ? " #{name.inspect}" : ''}")
          instance_exec(&block)
        end
      end
    end
  end
end
