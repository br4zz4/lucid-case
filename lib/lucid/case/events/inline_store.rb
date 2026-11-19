module Lucid
  class Case
    module Events
      # In-process store: no table. Delivery runs right after the outermost transaction commits.
      module InlineStore
        module_function

        def record(event)
          ActiveRecord.after_all_transactions_commit { Dispatcher.dispatch(event) }
        end
      end
    end
  end
end
