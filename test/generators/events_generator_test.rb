require "test_helper"
require "rails/generators/test_case"
require "generators/lucid/case/events/events_generator"

class EventsGeneratorTest < Rails::Generators::TestCase
  tests Lucid::Case::Generators::EventsGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "is reachable as lucid:case:events" do
    # arrange
    # act
    namespace = Lucid::Case::Generators::EventsGenerator.namespace

    # assert
    assert_equal "lucid:case:events", namespace
  end

  test "creates the timestamped migration" do
    # arrange
    # act
    run_generator

    # assert
    assert_migration "db/migrate/create_lucid_case_events.rb", /class CreateLucidCaseEvents < ActiveRecord::Migration/
  end

  test "migration creates the events table with its columns" do
    # arrange
    # act
    run_generator

    # assert
    assert_migration "db/migrate/create_lucid_case_events.rb" do |content|
      assert_match(/create_table :lucid_case_events/, content)
      assert_match(/t\.string :uuid, null: false/, content)
      assert_match(/t\.string :kind, null: false/, content)
      assert_match(/t\.string :name, null: false/, content)
      assert_match(/t\.string :source/, content)
      assert_match(/t\.string :step/, content)
      assert_match(/t\.string :result_type/, content)
      assert_match(/t\.boolean :success, null: false, default: true/, content)
      assert_match(/t\.json :payload, null: false/, content)
      assert_match(/t\.json :context, null: false/, content)
      assert_match(/t\.datetime :occurred_at, null: false/, content)
      assert_match(/t\.datetime :claimed_at/, content)
      assert_match(/t\.string :claim_token/, content)
      assert_match(/t\.datetime :delivered_at/, content)
      assert_match(/t\.datetime :created_at, null: false/, content)
    end
  end

  test "migration creates the indexes" do
    # arrange
    # act
    run_generator

    # assert
    assert_migration "db/migrate/create_lucid_case_events.rb" do |content|
      assert_match(/add_index :lucid_case_events, :uuid, unique: true/, content)
      assert_match(/add_index :lucid_case_events, %i\[delivered_at id\]|add_index :lucid_case_events, \[:delivered_at, :id\]/, content)
      assert_match(/add_index :lucid_case_events, %i\[name kind\]|add_index :lucid_case_events, \[:name, :kind\]/, content)
    end
  end

  test "creates the initializer configuring events" do
    # arrange
    # act
    run_generator

    # assert
    assert_file "config/initializers/lucid_case_events.rb" do |content|
      assert_match(/Lucid::Case\.configure/, content)
      assert_match(/^\s*config\.events\.recording = :enabled/, content)
      assert_match(/^\s*config\.events\.store = Rails\.env\.test\? \? :inline : :outbox/, content)
    end
  end

  test "initializer documents the remaining options as comments with their defaults" do
    # arrange
    # act
    run_generator

    # assert
    assert_file "config/initializers/lucid_case_events.rb" do |content|
      assert_match(/^\s*# config\.events\.transport = :active_job/, content)
      assert_match(/^\s*# config\.events\.queue = :default/, content)
      assert_match(/^\s*# config\.events\.retention = 7\.days/, content)
      assert_match(/^\s*# config\.events\.purge = :enabled/, content)
      assert_match(/^\s*# config\.events\.deduplication = :disabled/, content)
      assert_match(/^\s*# config\.events\.load_paths = %w\[app\/models\]/, content)
      assert_match(/^\s*# config\.events\.context = /, content)
      assert_match(/^\s*# config\.events\.around_delivery = /, content)
      assert_match(/^\s*# config\.events\.table_name = "lucid_case_events"/, content)
    end
  end
end
