module Lucid
  class Case
    # Callbacks of a Command, executed with +instance_exec(result)+.
    #
    # - +after_success+ / +after_failure+ run inside the transaction (when enabled).
    # - +after_commit+ runs only on success, after the outermost transaction commits;
    #   it is dropped if that transaction rolls back.
    module Hooks
      HOOK_TYPES = %i[success failure commit].freeze

      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :hook_registry, instance_accessor: false, instance_predicate: false,
                                             default: HOOK_TYPES.to_h { |type| [type, [].freeze] }.freeze
      end

      module ClassMethods
        def after_success(method_name = nil, &block)
          lucid_register_hook(:success, method_name, block)
        end

        def after_failure(method_name = nil, &block)
          lucid_register_hook(:failure, method_name, block)
        end

        def after_commit(method_name = nil, &block)
          lucid_register_hook(:commit, method_name, block)
        end

        private

        def lucid_register_hook(type, method_name, block)
          macro = "after_#{type == :commit ? 'commit' : type}"
          declare_side_effect!(macro)
          hook = method_name || block
          raise ArgumentError, "#{macro} needs a method name or a block" if hook.nil?

          self.hook_registry = hook_registry.merge(type => (hook_registry[type] + [hook]).freeze).freeze
        end
      end

      private

      def lucid_run_hooks(result)
        type = result.success? ? :success : :failure
        lucid_run_hook_list(self.class.hook_registry[type], result)
        return unless result.success?

        commit_hooks = self.class.hook_registry[:commit]
        return if commit_hooks.empty?

        ActiveRecord.after_all_transactions_commit { lucid_run_hook_list(commit_hooks, result) }
      end

      def lucid_run_hook_list(hooks, result)
        hooks.each do |hook|
          hook.is_a?(Symbol) ? send(hook, result) : instance_exec(result, &hook)
        end
      end
    end
  end
end
