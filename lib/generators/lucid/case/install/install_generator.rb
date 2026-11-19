require "rails/generators"

module Lucid
  class Case
    module Generators
      # Creates config/initializers/lucid_case.rb with every option and its default.
      #
      #   bin/rails g lucid:case:install
      class InstallGenerator < ::Rails::Generators::Base
        source_root File.expand_path("templates", __dir__)
        namespace "lucid:case:install"
        desc "Creates config/initializers/lucid_case.rb"

        def create_initializer
          template "lucid_case.rb.tt", "config/initializers/lucid_case.rb"
        end
      end
    end
  end
end
