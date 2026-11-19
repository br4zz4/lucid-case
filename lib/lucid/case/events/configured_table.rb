module Lucid
  class Case
    module Events
      # Gives an ActiveRecord model a table name read from +config.events+ at call time.
      module ConfiguredTable
        # @param option [Symbol] the +config.events+ option that holds the table name
        def configured_table(option)
          define_singleton_method(:table_name) do
            configured = Lucid::Case.configuration.events.public_send(option)
            if @table_name != configured && !@switching_table
              @switching_table = true
              begin
                self.table_name = configured
              ensure
                @switching_table = false
              end
            end
            @table_name || configured
          end
        end
      end
    end
  end
end
