$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "lucid/case"
require "minitest/autorun"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base; end

module CaseHelpers
  def build_case(name = "AnonymousCase", parent: Lucid::Case, &block)
    klass = Class.new(parent)
    klass.define_singleton_method(:name) { name }
    klass.class_eval(&block) if block
    klass
  end
end

class Minitest::Test
  include CaseHelpers
end
