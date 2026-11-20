require "active_job"
require "lucid/case/events/serializer"
require "lucid/case/events/dispatcher"
require "lucid/case/events/inline_store"
require "lucid/case/events/log"
require "lucid/case/events/recorder"
require "lucid/case/events/record"
require "lucid/case/events/outbox_store"
require "lucid/case/events/relay"
require "lucid/case/events/transports/active_job"
require "lucid/case/events/deduplication"
require "lucid/case/events/delivery_job"
require "lucid/case/events/cursor"
require "lucid/case/events/ordered_delivery_job"

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
      # @return [#publish] the configured transport
      def self.transport
        configured = Lucid::Case.configuration.events.transport
        configured == :active_job ? Transports::ActiveJob : configured
      end

      # Relays rows left pending (for example after a crash between commit and relay) and purges old delivered rows.
      # Schedule it (cron, solid_queue recurring).
      #
      # @raise [Lucid::Case::Error::RelayFailed] after the whole batch, when a transport failed
      def self.relay_pending(batch_size: 500)
        config = Lucid::Case.configuration
        log = config.logging == :enabled
        failed = []
        last_id = 0
        loop do
          rows = Record.relayable.where("created_at < ?", 1.minute.ago).where("id > ?", last_id).order(:id).limit(batch_size).pluck(:id, :uuid)
          break if rows.empty?

          last_id = rows.last.first
          failed.concat(Relay.relay(rows.map(&:last), log: log))
        end
        purge if config.events.purge == :enabled
        raise Error::RelayFailed, "transport failed for events: #{failed.join(', ')}" if failed.any?
      end

      # @api private
      # @return [ActiveRecord::Relation] outbox rows that may match one of +subscriptions+ (by kind, name and step)
      def self.rows_for(subscriptions)
        subscriptions.map { |item| Record.where(kind: item.kind.to_s, name: item.target_name, step: item.step&.to_s) }.reduce(:or)
      end

      # @api private
      def self.ordered_pending_ids
        by_subscriber = Registry.subscriptions.select(&:ordered).group_by(&:subscriber_id)
        by_subscriber.filter_map do |subscriber_id, subscriptions|
          floor = Cursor.find_by(subscriber: subscriber_id)&.last_event_id || 0
          rows_for(subscriptions).where("id > ?", floor).select(:id)
        end.reduce(:or)
      end

      # Deletes delivered rows older than +config.events.retention+ (and old deduplication marks), keeping the rows
      # an ordered subscriber still has to process. Called by +relay_pending+ when +config.events.purge+ is enabled.
      def self.purge
        config = Lucid::Case.configuration
        scope = Record.where.not(delivered_at: nil).where("delivered_at < ?", Time.current - Lucid::Case.configuration.events.retention)
        pending = ordered_pending_ids
        scope = scope.where.not(id: pending) if pending
        scope.delete_all
        return unless config.events.deduplication == :enabled

        DeliveryRecord.where("created_at < ?", Time.current - config.events.retention).delete_all
      end

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
          return false unless command?
          return events_setting == :enabled unless events_setting.nil?

          Events::Recorder.capturing? || Lucid::Case.configuration.events.recording == :enabled
        end
      end

      private

      # Records a Custom event, published after the transaction commits.
      #
      # @raise [Lucid::Case::Error::EmitOutsideCommand] when the case is not a Command
      def emit(name, **content)
        raise Error::EmitOutsideCommand, "#{self.class.name} is a #{self.class.kind}: only Commands can emit events" unless self.class.command?
        lucid_trigger_stale(kind: :custom, name: name.to_s, step: nil, type: nil, success: true, input: {}, content: content)
        return unless self.class.events_recording?

        lucid_record_event(kind: :custom, name: name.to_s, type: nil, success: true, input: {}, content: content)
      end

      def lucid_record_case_event(result)
        return unless self.class.command?

        lucid_trigger_stale(kind: :case, name: Events.event_name(self.class), step: nil, type: result.type, success: result.success?,
                            input: attribute_values, content: result.content)
        return unless self.class.events_recording?

        block = self.class.event_payload_block
        input = block ? {} : Lucid::Case.configuration.parameter_filter.filter(Serializer.normalize(attribute_values))
        content = block ? instance_exec(result, &block) : result.content
        lucid_record_event(kind: :case, name: Events.event_name(self.class), type: result.type, success: result.success?, input: input, content: content)
      end

      def lucid_record_step_event(name, outcome)
        return unless self.class.command?
        return unless outcome.is_a?(Result) || outcome.is_a?(Stepped::Directive)
        return if outcome.is_a?(Result) && outcome.failure?

        event_name = Events.event_name(self.class)
        lucid_trigger_stale(kind: :step, name: event_name, step: name, type: :ok, success: true, input: attribute_values, content: outcome.content)
        return unless self.class.events_recording?
        return if !Recorder.capturing? && Registry.matching(kind: :step, name: event_name, step: name, type: :ok, success: true).empty?

        type = outcome.is_a?(Result) ? outcome.type : :ok
        lucid_record_event(kind: :step, name: event_name, step: name, type: type, success: true, input: {}, content: outcome.content)
      end

      def lucid_trigger_stale(kind:, name:, step:, type:, success:, input:, content:)
        subscriptions = Registry.matching(kind: kind, name: name, step: step, type: type, success: success, in_process: true)
        return if subscriptions.empty?

        event = Event.new(id: SecureRandom.uuid, kind: kind, name: name, source: self.class.name, step: step, type: type, success: success,
                          input: input, content: content, occurred_at: Time.current)
        ActiveRecord.after_all_transactions_commit { subscriptions.each { |subscription| subscription.handler.call(event) } }
      end

      def lucid_record_event(kind:, name:, type:, success:, input:, content:, step: nil)
        config = Lucid::Case.configuration.events
        context = config.context&.call || {}
        event = lucid_build_event(kind, name, step, type, success, input, content, context)
        (@lucid_recorded_events ||= []) << event
        lucid_log(Events::Log.recorded(event))
        return Recorder.record(event) if Recorder.capturing?

        config.store == :inline ? InlineStore.record(event) : OutboxStore.record(event, log: self.class.logging?)
        event
      end

      def lucid_build_event(kind, name, step, type, success, input, content, context)
        input, content, context = lucid_round_trip(input, content, context)
        Event.new(id: SecureRandom.uuid, kind: kind, name: name, source: self.class.name, step: step, type: type, success: success,
                  input: input, content: content, context: context, occurred_at: Time.current)
      rescue ActiveJob::SerializationError => error
        lucid_log(Events::Log.not_recorded(name), level: :error) unless self.class.transactional?
        raise Error::UnserializableEvent, "event #{name.inspect} of #{self.class.name} has a payload that cannot be serialized: #{error.message}"
      end

      def lucid_round_trip(input, content, context)
        Serializer.round_trip(input, content, context)
      rescue ActiveJob::DeserializationError
        Serializer.dump(input, content, context)
        [Serializer.normalize(input), Serializer.normalize(content), Serializer.normalize(context)]
      end

      def lucid_log_events_kept
        return if self.class.transactional? || @lucid_recorded_events.blank?

        lucid_log(Events::Log.kept_after_raise(@lucid_recorded_events), level: :warn)
      end
    end
  end
end
