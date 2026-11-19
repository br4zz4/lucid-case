module Lucid
  class Case
    module Cache
      # Returned by +Query.fresh+: runs the query ignoring any cached entry and stores the new result.
      class Invocation
        def initialize(case_class)
          @case_class = case_class
        end

        def call(input = {}, **keywords)
          @case_class.new(input.to_h.merge(keywords)).lucid_refresh!.call
        end
      end
    end
  end
end
