module Lucid
  class Case
    # Shortcut for +kind :query+: read-only (writes raise ActiveRecord::ReadOnlyError) and cacheable.
    class Query < Case
      kind :query
    end
  end
end
