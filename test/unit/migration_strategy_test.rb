require File.expand_path(File.join(File.dirname(__FILE__), '../test_helper.rb'))

require 'active_record/connection_adapters/abstract/schema_definitions'
require 'table_migrator'

class MigrationStrategyTest < Test::Unit::TestCase
  MigrationStrategy = ::TableMigrator::MigrationStrategy
  Table = ::ActiveRecord::ConnectionAdapters::Table
  Connection = ActiveRecord::Base.connection

  context "An instance of MigrationStrategy" do
    setup do
      create_users
      @strategy = MigrationStrategy.new(:users)
    end

    should "implement all Table methods" do
      Table.instance_methods.each do |table_method|
        assert @strategy.respond_to?(table_method), "Does not respond to method '#{table_method}'"
      end
    end

    should "have correct existing columns list" do
      expected_columns = Connection.columns(:users).map {|c| c.name }
      assert_equal expected_columns.sort, @strategy.existing_columns
    end
  end
end
