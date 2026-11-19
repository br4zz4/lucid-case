module Lucid
  class Case
    # Handles exceptions raised by +call!+ or a step.
    #
    # The handler may return a Result (it becomes the outcome); otherwise the outcome is
    # +failure(:exception, error: e)+. Exceptions with no matching +catch+ propagate.
    #
    # @example
    #   catch(Timeout::Error) { |ctx| failure(:timeout, error: ctx.error.message) }
    module Catching
      Context = Struct.new(:error, :case)
      Handler = Struct.new(:classes, :block)

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :catch_handlers, instance_accessor: false, instance_predicate: false, default: [].freeze
      end

      module ClassMethods
        # Registers a handler for one or more exception classes. Handlers run in declaration order.
        def catch(*classes, &block)
          raise ArgumentError, "catch needs at least one exception class" if classes.empty?
          raise ArgumentError, "catch needs a block" unless block

          self.catch_handlers = (catch_handlers + [Handler.new(classes, block)]).freeze
        end
      end

      private

      def lucid_guarded
        yield
      rescue StandardError => error
        handlers = self.class.catch_handlers.select { |handler| handler.classes.any? { |klass| error.is_a?(klass) } }
        raise if handlers.empty?

        outcome = nil
        handlers.each do |handler|
          returned = instance_exec(Context.new(error, self), &handler.block)
          outcome = returned if returned.is_a?(Result)
        end
        outcome ||= failure(:exception, error: error)
        lucid_log_caught(error, outcome)
        outcome
      end
    end
  end
end
