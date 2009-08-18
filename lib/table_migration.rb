class TableMigration < ActiveRecord::Migration
  class << self
    attr_reader :table_migrator
    delegate :schema_changes,          :to => :table_migrator
    delegate :base_copy_query,         :to => :table_migrator
    delegate :on_duplicate_update_map, :to => :table_migrator
  end

  def self.migrates(table_name, config = {})
    default = {:migration_name => name.underscore}
    puts default.update(config).inspect
    @table_migrator = TableMigrator.new(table_name, default.update(config))
  end

  def self.up
    table_migrator.up!
    raise "Dry Run!" if table_migrator.dry_run?
  end

  def self.down
    table_migrator.down!
    raise "Dry Run!" if table_migrator.dry_run?
  end
end