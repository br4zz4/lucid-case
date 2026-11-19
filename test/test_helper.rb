$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "lucid/case"
require "active_job"
require "logger"
require "stringio"
require "active_support/testing/time_helpers"
require "minitest/autorun"

GlobalID.app = "lucid-case-test"
ActiveJob::Base.queue_adapter = :test

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.include GlobalID::Identification
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
  end

  create_table :orders, force: true do |t|
    t.string :status
  end

  create_table :lucid_case_events, force: true do |t|
    t.string :uuid, null: false
    t.string :kind, null: false
    t.string :name, null: false
    t.string :source
    t.string :step
    t.string :result_type
    t.boolean :success, null: false, default: true
    t.json :payload, null: false
    t.json :context, null: false
    t.datetime :occurred_at, null: false
    t.datetime :claimed_at
    t.string :claim_token
    t.datetime :delivered_at
    t.datetime :created_at, null: false
  end
  add_index :lucid_case_events, :uuid, unique: true
end

class User < ActiveRecord::Base; end
class Order < ActiveRecord::Base; end

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

class EventsTest < Minitest::Test
  Error = Lucid::Case::Error

  attr_reader :events, :log

  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
    Lucid::Case::Events::Registry.clear!
    @events = []
    @log = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(@log)
    with_events
    User.delete_all
    Order.delete_all
    Thread.current[:lucid_test_tenant] = nil
  end

  def teardown
    Lucid::Case::Events::Registry.clear!
    Lucid::Case.instance_variable_set(:@configuration, @original)
    User.delete_all
    Order.delete_all
    Thread.current[:lucid_test_tenant] = nil
  end

  def with_events(store: :inline, recording: :enabled)
    Lucid::Case.configuration.events.store = store
    Lucid::Case.configuration.events.recording = recording
  end

  def spy(target, as: :spy, **options)
    Lucid::Case.subscribe(target, as: as, **options) { |event| @events << event }
  end

  def build_command(name = "Enrollment::Approve", &block)
    build_case(name, parent: Lucid::Case::Command, &block)
  end

  def build_subscriber(name, &block)
    build_case(name, parent: Lucid::Case::Subscriber, &block)
  end

  def event_log_lines
    log.string.lines.select { |line| line.include?("event") }
  end
end

class CollectingTransport
  attr_reader :published

  def initialize
    @published = []
  end

  def publish(event)
    @published << event
  end
end

class FailingTransport
  attr_reader :attempts

  def initialize
    @attempts = 0
  end

  def publish(_event)
    @attempts += 1
    raise IOError, "broker down"
  end
end

class OutboxTest < EventsTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  UUID = "\\h{8}-\\h{4}-\\h{4}-\\h{4}-\\h{12}".freeze

  def setup
    super
    with_events(store: :outbox)
    Lucid::Case.configuration.events.table_name = "lucid_case_events"
    record_class.reset_column_information
    record_class.delete_all
    clear_enqueued_jobs
  end

  def teardown
    cleanup_records
  ensure
    super
  end

  def cleanup_records
    Lucid::Case.configuration.events.table_name = "lucid_case_events"
    record_class.reset_column_information
    record_class.delete_all
    record_class.reset_column_information
  end

  def record_class
    Lucid::Case::Events::Record
  end

  def hold_events
    transport = FailingTransport.new
    Lucid::Case.configuration.events.transport = transport
    transport
  end

  def collect_events
    transport = CollectingTransport.new
    Lucid::Case.configuration.events.transport = transport
    transport
  end

  def approve_command(logging: :disabled)
    build_command("Enrollment::Approve") do
      logging logging
      attributes :enrollment
      define_method(:call!) { success(enrollment: enrollment) }
    end
  end

  def age_pending!(age = 5.minutes)
    record_class.update_all(created_at: age.ago)
  end

  def perform_inline
    adapter = ActiveJob::Base.queue_adapter
    adapter.perform_enqueued_jobs = true
    adapter.perform_enqueued_at_jobs = true
    yield
  ensure
    adapter.perform_enqueued_jobs = false
    adapter.perform_enqueued_at_jobs = false
  end

  def delivery_arguments
    enqueued_jobs.select { |job| job["job_class"] == "Lucid::Case::Events::DeliveryJob" }
                 .map { |job| ActiveJob::Arguments.deserialize(job["arguments"]) }
  end
end
