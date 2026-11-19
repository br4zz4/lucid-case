module Lucid
  class Case
    module Events
      # Makes sure Subscribers are registered: clears the registry on every (re)load and, when the app
      # does not eager load, loads the directories in +config.events.load_paths+.
      module Loader
        module_function

        # @param root [Pathname, String] application root
        # @param autoloader [#eager_load_dir] e.g. +Rails.autoloaders.main+
        # @param eager_load [Boolean] whether Rails eager loads the whole app anyway
        # @raise [ArgumentError] when a load path does not exist
        def prepare!(root:, autoloader:, eager_load: false)
          Registry.clear!
          directories = Lucid::Case.configuration.events.load_paths.map do |path|
            directory = File.expand_path(path.to_s, root.to_s)
            raise ArgumentError, "config.events.load_paths: #{path} does not exist (looked for #{directory})" unless Dir.exist?(directory)

            directory
          end
          return if eager_load

          directories.each { |directory| autoloader.eager_load_dir(directory) }
        end
      end
    end
  end
end
