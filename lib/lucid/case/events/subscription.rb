module Lucid
  class Case
    module Events
      # One registered interest: which Event (+kind+, +target_name+, +step+, +on+) goes to which handler.
      Subscription = Struct.new(:target_name, :kind, :step, :on, :ordered, :subscriber_id, :handler, :in_process, keyword_init: true) do
        # @return [Boolean] whether this subscription wants an Event with the given traits
        def match?(kind:, name:, step:, type:, success:)
          return false unless self.kind == kind && target_name == name && self.step == step
          return true if kind == :custom

          conditions = Array(on)
          conditions.include?(:any) ||
            (success && conditions.include?(:success)) ||
            (!success && conditions.include?(:failure)) ||
            (!type.nil? && conditions.include?(type.to_sym))
        end
      end
    end
  end
end
