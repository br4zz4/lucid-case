require "time"
require "active_job"

module Lucid
  class Case
    # Immutable business fact published by a Command (Case event, Step event) or by +emit+ (Custom event).
    #
    # @example
    #   Lucid::Case::Event.from_h(event.to_h) == event # => true
    class Event
      FIELDS = %i[id kind name source step type success input content context occurred_at].freeze
      SYMBOL_FIELDS = %i[kind step type].freeze

      # @return [String] UUID, stable across deliveries (use it for idempotency)
      attr_reader :id
      # @return [Symbol] +:case+, +:step+ or +:custom+
      attr_reader :kind
      # @return [String] event name, e.g. +"enrollment.approve"+
      attr_reader :name
      # @return [String, nil] class that produced the event
      attr_reader :source
      # @return [Symbol, nil] step name of a Step event
      attr_reader :step
      # @return [Symbol, nil] +:ok+ or the failure type; +nil+ in a Custom event
      attr_reader :type
      # @return [Hash] attributes of the case (filtered by +filter_parameters+)
      attr_reader :input
      # @return [Hash] content of the result, the step or the +emit+
      attr_reader :content
      # @return [Hash] value of +config.events.context+ at recording time
      attr_reader :context
      # @return [Time]
      attr_reader :occurred_at

      def initialize(id:, kind:, name:, source:, occurred_at:, step: nil, type: nil, success: true, input: {}, content: {}, context: {})
        @id = id
        @kind = kind.to_sym
        @name = name.to_s
        @source = source
        @step = step&.to_sym
        @type = type&.to_sym
        @success = success ? true : false
        @input = input
        @content = content
        @context = context
        @occurred_at = occurred_at
        freeze
      end

      def success?
        @success
      end

      # @return [Hash{Symbol => Object}] JSON-friendly representation; records in +input+ and +content+ are GlobalIDs
      def to_h
        {
          id: id, kind: kind.to_s, name: name, source: source, step: step&.to_s, type: type&.to_s,
          success: success?, input: Event.dump(input), content: Event.dump(content), context: Event.dump(context),
          occurred_at: occurred_at.utc.iso8601(6)
        }
      end

      # @param hash [Hash] result of +to_h+, with string or symbol keys
      # @return [Lucid::Case::Event]
      def self.from_h(hash)
        data = hash.to_h.symbolize_keys
        new(
          id: data[:id], kind: data[:kind], name: data[:name], source: data[:source], step: data[:step],
          type: data[:type], success: data.fetch(:success, true),
          input: load(data[:input]), content: load(data[:content]), context: load(data[:context]), occurred_at: parse_time(data[:occurred_at])
        )
      end

      def ==(other)
        other.is_a?(Event) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def self.dump(value)
        ActiveJob::Arguments.serialize([value]).first
      end

      def self.load(value)
        deep_symbolize(ActiveJob::Arguments.deserialize([value || {}]).first)
      end
      private_class_method :load

      def self.deep_symbolize(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), memo| memo[key.to_sym] = deep_symbolize(item) }
        when Array then value.map { |item| deep_symbolize(item) }
        else value
        end
      end
      private_class_method :deep_symbolize

      def self.parse_time(value)
        value.is_a?(String) ? Time.iso8601(value) : value
      end
      private_class_method :parse_time
    end
  end
end
