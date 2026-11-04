# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/solid_queue/rate_limit/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SolidQueue::RateLimit::InstallGenerator
  destination Rails.root.join("tmp/install_generator_test")
  setup :prepare_destination

  test "copies the migration to the queue database migrations path" do
    run_generator

    assert_migration "db/queue_migrate/create_solid_queue_rate_limits.rb" do |migration|
      assert_match(/class CreateSolidQueueRateLimits/, migration)
      assert_match(/create_table :solid_queue_rate_limits/, migration)
      assert_match(/t\.string :key, null: false$/, migration)
      assert_match(/t\.datetime :tat, null: false$/, migration)
      assert_match(/t\.datetime :deferred_until$/, migration)
      assert_match(/t\.index :key, unique: true$/, migration)
      assert_no_match(/foreign_key|solid_queue_jobs/, migration)
    end
  end

  test "copies the migration to another database's migrations path" do
    run_generator %w[ --database primary ]

    assert_migration "db/migrate/create_solid_queue_rate_limits.rb"
  end

  test "skips a migration that has already been copied" do
    run_generator
    run_generator

    assert_equal 1, Dir.glob(File.join(destination_root, "db/queue_migrate/*_create_solid_queue_rate_limits.rb")).count
  end
end
