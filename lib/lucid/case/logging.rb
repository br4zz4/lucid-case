module Lucid
  class Case
    # Optional, structured logging of what a case does: the call with its input, every step,
    # caught exceptions, cache hits and the final result.
    #
    # Off by default. Turn it on globally (+config.logging = :enabled+) or per case
    # (+logging :enabled+ / +logging :disabled+). Only names (input keys, content keys, types) are
    # logged unless +config.log_values+ is on, and values are always passed through
    # the app's +filter_parameters+.
    module Logging
      PREFIX = "[Lucid::Case]".freeze

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :logging_setting, instance_accessor: false, instance_predicate: false, default: nil
        base.class_attribute :logging_values_setting, instance_accessor: false, instance_predicate: false, default: nil
      end

      module ClassMethods
        # Turns logging on or off for this case, overriding +config.logging+, and optionally
        # whether values are logged (always filtered), overriding +config.log_values+.
        #
        # @param value [Symbol] +:enabled+ or +:disabled+
        # @param values [Boolean, nil] +true+ to log input and content values, +false+ for names only
        #
        # @example
        #   logging :enabled, values: true
        def logging(value, values: nil)
          Configuration.switch!(:logging, value)
          self.logging_setting = value
          self.logging_values_setting = values unless values.nil?
        end

        # @return [Boolean] whether this case logs right now
        def logging?
          (logging_setting || Lucid::Case.configuration.logging) == :enabled
        end

        # @return [Boolean] whether this case logs values (filtered) and not only names
        def logging_values?
          logging_values_setting.nil? ? Lucid::Case.configuration.log_values : logging_values_setting
        end
      end

      # Logger scoped to the case, for your own lines. It follows the case's +logging+ setting.
      #
      # @example
      #   logger.info("charging #{order.id}")
      #   logger.warn { "retrying" }
      #
      # @return [Lucid::Case::Logging::Scoped]
      def logger
        @lucid_scoped_logger ||= Scoped.new(self)
      end

      # Logger scoped to a case instance. Lines go through the case's logging switch.
      class Scoped
        def initialize(owner)
          @owner = owner
        end

        %i[debug info warn error].each do |level|
          define_method(level) do |message = nil, &block|
            @owner.send(:lucid_log, block ? block.call : message, level: level)
          end
        end
      end

      private

      def lucid_log(message, level: nil)
        return unless self.class.logging?

        config = Lucid::Case.configuration
        logger = config.logger
        return unless logger

        logger.public_send(level || config.log_level) { "#{PREFIX} #{self.class.name} #{message}" }
      end

      def lucid_describe_data(data)
        return data.keys.inspect unless self.class.logging_values?

        Lucid::Case.configuration.parameter_filter.filter(data).inspect
      end

      def lucid_describe_result(result)
        head = result.success? ? "success" : "failure(#{result.type.inspect})"
        "#{head} content=#{lucid_describe_data(result.content)}"
      end

      def lucid_log_call_started
        lucid_log("called input=#{lucid_describe_data(attribute_values)}")
      end

      def lucid_log_call_finished(result, started_at)
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
        cache = @instrumentation_payload && @instrumentation_payload[:cache]
        suffix = cache ? " cache=#{cache}" : ""
        lucid_log("#{lucid_describe_result(result)}#{suffix} in #{elapsed}ms")
      end

      def lucid_describe_error(error)
        self.class.logging_values? ? "#{error.class}: #{error.message}" : error.class.to_s
      end

      def lucid_log_call_raised(error)
        lucid_log("raised #{lucid_describe_error(error)}", level: :error)
      end

      def lucid_log_step(name, outcome)
        description = case outcome
                      when Result then lucid_describe_result(outcome)
                      else outcome.action == :skip_to ? "skip_to(#{outcome.step.inspect})" : "continue"
                      end
        lucid_log("step #{name.inspect} -> #{description}")
      end

      def lucid_log_guard(name, result)
        lucid_log("guard #{name.inspect} -> #{lucid_describe_result(result)}")
      end

      def lucid_log_step_raised(name, error)
        lucid_log("step #{name.inspect} raised #{lucid_describe_error(error)}", level: :warn)
      end

      def lucid_log_caught(error, outcome)
        lucid_log("caught #{lucid_describe_error(error)} -> #{lucid_describe_result(outcome)}", level: :warn)
      end
    end
  end
end
