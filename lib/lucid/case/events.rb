require "active_job"
require "lucid/case/events/serializer"
require "lucid/case/events/dispatcher"
require "lucid/case/events/inline_store"
require "lucid/case/events/log"

module Lucid
  class Case
    # Records an Event for every Command call (Case event), for assigned steps (Step event) and for +emit+
    # (Custom event), in the same transaction as the Command's data.
    #
    # Off by default: turn it on with +config.events.recording = :enabled+ or +events :enabled+ in a Command.
    #
    # @example
    #   class Payment::Charge < Lucid::Case::Command
    #     events :enabled
    #     event_payload { |result| { payment_id: result[:payment].id } }
    #
    #     def call!
    #       emit(:credit_limit_reached, customer_id: payment.customer_id) if payment.customer.at_limit?
    #       success(payment: payment)
    #     end
    #   end
    module Events
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :events_setting, instance_accessor: false, instance_predicate: false, default: nil
        base.class_attribute :event_payload_block, instance_accessor: false, instance_predicate: false, default: nil
      end

      module ClassMethods
        # Turns event recording on or off for this Command, overriding +config.events.recording+.
        #
        # @param value [Symbol] +:enabled+ or +:disabled+
        def events(value)
          Lucid::Case::Configuration.switch!(:events, value)
          declare_side_effect!("events")
          self.events_setting = value
        end

        # Shapes the content of the Case event: the block receives the result and returns a Hash.
        # The event then carries no input.
        def event_payload(&block)
          raise ArgumentError, "event_payload needs a block" unless block

          declare_side_effect!("event_payload")
          self.event_payload_block = block
        end

        # @return [Boolean] whether this Command records Events right now
        def events_recording?
          command? && (events_setting || Lucid::Case.configuration.events.recording) == :enabled
        end
      end

      private

      # Records a Custom event, published after the transaction commits.
      #
      # @raise [Lucid::Case::Error::EmitOutsideCommand] when the case is not a Command
      def emit(name, **content)
        raise Error::EmitOutsideCommand, "#{self.class.name} is a #{self.class.kind}: only Commands can emit events" unless self.class.command?
        return unless self.class.events_recording?

        lucid_record_event(kind: :custom, name: name.to_s, type: nil, success: true, input: {}, content: content)
      end

      def lucid_record_case_event(result)
        return unless self.class.events_recording?

        block = self.class.event_payload_block
        input = block ? {} : Lucid::Case.configuration.parameter_filter.filter(attribute_values)
        content = block ? instance_exec(result, &block) : result.content
        lucid_record_event(kind: :case, name: Events.event_name(self.class), type: result.type, success: result.success?, input: input, content: content)
      end

      def lucid_record_step_event(name, outcome)
        return unless self.class.events_recording?
        return if outcome.is_a?(Result) && outcome.failure?

        event_name = Events.event_name(self.class)
        return if Registry.matching(kind: :step, name: event_name, step: name, type: :ok, success: true).empty?

        type = outcome.is_a?(Result) ? outcome.type : :ok
        lucid_record_event(kind: :step, name: event_name, step: name, type: type, success: true, input: {}, content: outcome.content)
      end

      def lucid_record_event(kind:, name:, type:, success:, input:, content:, step: nil)
        config = Lucid::Case.configuration.events
        raise NotImplementedError, "config.events.store :outbox is not available yet; use :inline" unless config.store == :inline

        context = config.context&.call || {}
        event = lucid_build_event(kind, name, step, type, success, input, content, context)
        (@lucid_recorded_events ||= []) << event
        lucid_log(Events::Log.recorded(event))
        InlineStore.record(event)
        event
      end

      def lucid_build_event(kind, name, step, type, success, input, content, context)
        input, content, context = Serializer.round_trip(input, content, context)
        Event.new(id: SecureRandom.uuid, kind: kind, name: name, source: self.class.name, step: step, type: type, success: success,
                  input: input, content: content, context: context, occurred_at: Time.current)
      rescue ActiveJob::SerializationError => error
        lucid_log(Events::Log.not_recorded(name), level: :error) unless self.class.transactional?
        raise Error::UnserializableEvent, "event #{name.inspect} of #{self.class.name} has a payload that cannot be serialized: #{error.message}"
      end

      def lucid_log_events_kept
        return if self.class.transactional? || @lucid_recorded_events.blank?

        lucid_log(Events::Log.kept_after_raise(@lucid_recorded_events), level: :warn)
      end
    end
  end
end
