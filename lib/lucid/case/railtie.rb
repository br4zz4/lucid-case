require "rails/railtie"

module Lucid
  class Case
    class Railtie < ::Rails::Railtie
      config.to_prepare do
        Lucid::Case::Events::Loader.prepare!(root: Rails.root, autoloader: Rails.autoloaders.main, eager_load: Rails.application.config.eager_load)
      end

      config.after_initialize do
        Lucid::Case.booted!
        Lucid::Case.validate_configuration!
      end
    end
  end
end
