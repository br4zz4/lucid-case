module Lucid
  class Case
    # Writes a case as an ordered pipeline of steps instead of +call!+.
    #
    # Each step returns +continue(**content)+ (keep going, accumulating content),
    # +skip_to(:step, **content)+ (jump forward) or +success+ / +failure+ (finish).
    # The final result carries the accumulated content (see +accumulate+ to turn that off).
    # Define +call!+ or steps, never both.
    #
    # @example
    #   class Provisioning::Run < Lucid::Case::Command
    #     attributes :provisioning
    #
    #     step(:start)  { provisioning.update!(status: :running); continue }
    #     step(:finish) { success(provisioning: provisioning) }
    #
    #     catch(StandardError) { |ctx| failure(:failed, error: ctx.error.message) }
    #   end
    module Stepped
      Directive = Struct.new(:action, :step, :content)

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :step_definitions, instance_accessor: false, instance_predicate: false, default: [].freeze
        base.class_attribute :accumulate_setting, instance_accessor: false, instance_predicate: false, default: nil
      end

      module ClassMethods
        # Declares a step. The block runs with the case as +self+.
        #
        # @raise [Lucid::Case::Error::AmbiguousDefinition] when the case also defines +call!+
        def step(name, &block)
          raise ArgumentError, "step #{name.inspect} needs a block" unless block

          if instance_method(:call!).owner != Lucid::Case
            raise Error::AmbiguousDefinition, "#{self.name} defines call! and cannot declare step #{name.inspect}"
          end

          self.step_definitions = (step_definitions + [[name.to_sym, block]]).freeze
        end

        # @api private
        def method_added(method_name)
          super
          return unless method_name == :call! && step_definitions.any?

          raise Error::AmbiguousDefinition, "#{name} declares steps and cannot define call!"
        end

        def stepped?
          step_definitions.any?
        end

        # Turns accumulation of +continue+ content on or off for this case, overriding +config.accumulate+.
        # When off, only the content given to the final +success+ / +failure+ is returned.
        #
        # @param value [Symbol] +:enabled+ or +:disabled+
        def accumulate(value)
          Configuration.switch!(:accumulate, value)
          self.accumulate_setting = value
        end

        # @return [Boolean] whether this case accumulates the content of +continue+ / +skip_to+
        def accumulating?
          (accumulate_setting || Lucid::Case.configuration.accumulate) == :enabled
        end
      end

      private

      def continue(**content)
        Directive.new(:continue, nil, content)
      end

      def skip_to(step, **content)
        Directive.new(:skip_to, step.to_sym, content)
      end

      def lucid_run_body
        self.class.stepped? ? lucid_run_steps : call!
      end

      def lucid_run_step(name, block)
        outcome = instance_exec(&block)
        lucid_log_step(name, outcome) if outcome.is_a?(Result) || outcome.is_a?(Directive)
        outcome
      rescue StandardError => error
        lucid_log_step_raised(name, error)
        raise
      end

      def lucid_run_steps
        accumulated = {}
        target = nil

        self.class.step_definitions.each do |name, block|
          next if target && target != name

          target = nil
          outcome = lucid_run_step(name, block)

          case outcome
          when Result then return outcome.merge_content(accumulated)
          when Directive
            accumulated.merge!(outcome.content) if self.class.accumulating?
            target = outcome.step if outcome.action == :skip_to
          else
            raise Error::UnexpectedResult, "step #{name.inspect} of #{self.class.name} must return continue, skip_to, success or failure"
          end
        end

        raise ArgumentError, "step #{target.inspect} not found in #{self.class.name}" if target

        raise Error::UnexpectedResult, "#{self.class.name} finished its steps without success or failure"
      end
    end
  end
end
