module Lucid
  class Case
    # Immutable outcome of a case call.
    #
    # @example
    #   result = Users::Create.call(params: { name: "Ana" })
    #   result.on_success { |r| redirect_to r[:user] }
    #         .on_failure(:invalid_attributes) { |r| render_errors(r[:errors]) }
    class Result
      # @return [Symbol] +:ok+ on success, or the failure type (default +:error+)
      attr_reader :type
      # @return [Hash] the content given to +success+ / +failure+
      attr_reader :content
      # @return [Class, nil] the case class that produced this result
      attr_reader :case_class
      # @return [Time, nil] when a cached result was computed
      attr_reader :cached_at
      # @return [Time, nil] when a cached result expires
      attr_reader :expires_at

      alias data content

      def initialize(success:, type:, content:, case_class: nil, cached_at: nil, expires_at: nil)
        @success = success
        @type = type
        @content = content.dup.freeze
        @case_class = case_class
        @cached_at = cached_at
        @expires_at = expires_at
        freeze
      end

      def success?
        @success
      end

      def failure?
        !@success
      end

      # @return [Boolean] true when this result came from the cache
      def cached?
        !cached_at.nil?
      end

      def [](key)
        content[key]
      end

      def to_h
        content
      end

      # Runs the block when the result is a success. Returns +self+.
      def on_success
        yield self if success?
        self
      end

      # Runs the block when the result is a failure, optionally only for +type+. Returns +self+.
      def on_failure(type = nil)
        yield self if failure? && (type.nil? || type == self.type)
        self
      end

      # Supports pattern matching: +in { type: :not_found, id: }+.
      def deconstruct_keys(_keys)
        content.merge(type: type, success: success?)
      end

      # @api private
      def lucid_with_cache(cached_at:, expires_at:)
        self.class.new(success: success?, type: type, content: content, case_class: case_class,
                       cached_at: cached_at, expires_at: expires_at)
      end

      # @api private
      def with_case_class(klass)
        self.class.new(success: success?, type: type, content: content, case_class: klass,
                       cached_at: cached_at, expires_at: expires_at)
      end

      # @api private
      def merge_content(extra)
        self.class.new(success: success?, type: type, content: extra.merge(content), case_class: case_class,
                       cached_at: cached_at, expires_at: expires_at)
      end
    end
  end
end
