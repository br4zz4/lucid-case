require "rails/generators"
require "rails/generators/migration"

module Lucid
  class Case
    module Generators
      # Creates the outbox and deduplication migrations and config/initializers/lucid_case_events.rb.
      #
      #   bin/rails g lucid:case:events
      class EventsGenerator < ::Rails::Generators::Base
        include ::Rails::Generators::Migration

        source_root File.expand_path("templates", __dir__)
        namespace "lucid:case:events"
        desc "Creates the lucid_case_events migration and config/initializers/lucid_case_events.rb"

        def self.next_migration_number(dirname)
          next_number = Time.now.utc.strftime("%Y%m%d%H%M%S")
          existing = Dir.glob(File.join(dirname, "*.rb")).map { |path| File.basename(path)[/\A\d+/].to_i }.max.to_i
          [next_number.to_i, existing + 1].max.to_s
        end

        def create_migrations
          migration_template "create_lucid_case_events.rb.tt", "db/migrate/create_lucid_case_events.rb"
          migration_template "create_lucid_case_deliveries.rb.tt", "db/migrate/create_lucid_case_deliveries.rb"
        end

        def create_initializer
          template "lucid_case_events.rb.tt", "config/initializers/lucid_case_events.rb"
        end

        private

        def migration_version
          "[#{ActiveRecord::Migration.current_version}]"
        end
      end
    end
  end
end
