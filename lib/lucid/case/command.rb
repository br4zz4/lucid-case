module Lucid
  class Case
    # Shortcut for +kind :command+: writes, transactional by default, supports hooks.
    class Command < Case
      kind :command
    end
  end
end
