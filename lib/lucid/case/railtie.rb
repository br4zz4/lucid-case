require "rails/railtie"

module Lucid
  class Case
    class Railtie < ::Rails::Railtie
      config.after_initialize do
        Lucid::Case.booted!
        Lucid::Case.validate_configuration!
      end
    end
  end
end
