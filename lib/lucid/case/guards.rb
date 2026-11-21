module Lucid
  class Case
    # Fail-fast guards: business conditions that end the case with a typed failure before the body runs.
    #
    # A guard is a predicate declared with +fail_if+. When it holds, the case returns
    # +failure(type, errors: [message], **extras)+ and nothing else runs. Guards run after the attribute
    # validations and before +call!+ or the steps, in declaration order (parents first); the first one that
    # holds wins.
    #
    # The message is resolved at failure time, in the current locale:
    # 1. +message:+ as a String is used as is;
    # 2. +message:+ as a Symbol is an I18n key;
    # 3. otherwise +<case name underscored, dots for />.<type>+, then +lucid_case.failures.<type>+,
    #    then +type.to_s.humanize+.
    #
    # @example
    #   class ClassEnrollment::Create < Lucid::Case::Command
    #     attributes :student_id, :school_class_id
    #
    #     fail_if :class_full?
    #     fail_if :already_enrolled?, as: :duplicate, with: :student
    #     fail_if(:no_seats) { school_class.seats.zero? }
    #
    #     def call!
    #       success(enrollment: ClassEnrollment.create!(student: student, school_class: school_class))
    #     end
    #   end
    module Guards
      Guard = Struct.new(:name, :type, :block, :message, :with)

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :guard_definitions, instance_accessor: false, instance_predicate: false, default: [].freeze
      end

      module ClassMethods
        # Declares a guard. Without a block, +name+ is a method of the case (public or private) and the
        # failure type is the name without the trailing +?+. With a block, +name+ is the failure type and the
        # block runs with the case as +self+.
        #
        # @param name [Symbol, String] predicate method name, or the failure type when a block is given
        # @param as [Symbol, nil] failure type for a method guard (defaults to the name without +?+)
        # @param message [String, Symbol, nil] literal message, or an I18n key when a Symbol
        # @param with [Symbol, Array<Symbol>, nil] methods of the case whose values are added to the failure content
        # @raise [ArgumentError] on a missing or blank name, an invalid +as:+, a block guard named with +?+, +as:+ with a block,
        #   a +message:+ that is not a String or Symbol, or an invalid +with:+
        def fail_if(name = nil, as: nil, message: nil, with: nil, &block)
          raise ArgumentError, "fail_if needs a name" if name.nil? || !(name.is_a?(Symbol) || name.is_a?(String)) || name.empty?
          raise ArgumentError, "fail_if as: must be a Symbol or a String" unless as.nil? || ((as.is_a?(Symbol) || as.is_a?(String)) && !as.empty?)
          raise ArgumentError, "fail_if with a block takes the failure type, without a trailing ?: #{name.inspect}" if block && name.to_s.end_with?("?")
          raise ArgumentError, "fail_if with a block does not accept as:" if block && as
          raise ArgumentError, "fail_if message: must be a String or a Symbol" unless message.nil? || message.is_a?(String) || message.is_a?(Symbol)

          name = name.to_sym
          type = block ? name : (as || name.to_s.delete_suffix("?")).to_sym
          guard = Guard.new(name, type, block, message, lucid_guard_with(with)).freeze
          self.guard_definitions = (guard_definitions + [guard]).freeze
        end

        private

        def lucid_guard_with(with)
          return [].freeze if with.nil?

          names = with.is_a?(Array) ? with : [with]
          raise ArgumentError, "fail_if with: must be a Symbol or an Array of Symbols" unless names.all?(Symbol)
          raise ArgumentError, "fail_if with: cannot include :errors, it is reserved for the failure message" if names.include?(:errors)

          names.freeze
        end
      end

      private

      # Ends the case with +failure(type, errors: [message], **content)+. Use it in the body for checks that
      # only make sense in the middle of the case.
      #
      # @param type [Symbol] failure type
      # @param message [String, Symbol, nil] literal message, or an I18n key when a Symbol
      # @param content [Hash] extra content for the result (+errors+ is reserved)
      # @return [Lucid::Case::Result]
      # @raise [ArgumentError] when +content+ includes +errors+
      def fail_with(type, message: nil, **content)
        raise ArgumentError, "fail_with content cannot include :errors, it is reserved for the failure message" if content.key?(:errors)

        failure(type.to_sym, errors: [lucid_failure_message(type.to_sym, message)], **content)
      end

      def lucid_run_guards
        self.class.guard_definitions.each do |guard|
          next unless lucid_guard_holds?(guard)

          extras = guard.with.to_h { |reader| [reader, send(reader)] }
          result = failure(guard.type, errors: [lucid_failure_message(guard.type, guard.message)], **extras)
          lucid_log_guard(guard.name, result)
          return result
        end
        nil
      end

      def lucid_guard_holds?(guard)
        guard.block ? instance_exec(&guard.block) : send(guard.name)
      end

      def lucid_failure_message(type, message)
        case message
        when String then message
        when Symbol then I18n.t(message)
        else
          fallbacks = [:"lucid_case.failures.#{type}", type.to_s.humanize]
          scope = self.class.name&.underscore&.tr("/", ".")
          key = scope ? :"#{scope}.#{type}" : fallbacks.shift
          I18n.t(key, default: fallbacks)
        end
      end
    end
  end
end
