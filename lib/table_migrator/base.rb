module TableMigrator
  class Base

    attr_accessor :table, :config
    attr_accessor :schema_changes, :column_names, :quoted_column_names, :base_copy_query

    def initialize(table, config = {})
      self.table = table
      
      defaults = { :dry_run => false, :create_temp_table => true, :delta_column => 'updated_at'}
      self.config = defaults.merge(config)
    end

    def up!
      engine.up!
    end

    def down!
      engine.down!
    end

    # config methods

    def schema_changes
      @schema_changes ||= []
    end

    def change_table(&block)
      @strategy = ChangeTableStrategy.new(table, config, connection, &block)
    end

    # helpers

    def column_names
      @column_names ||= connection.columns(table).map { |c| c.name }
    end

    def quoted_column_names
      @quoted_column_names ||= column_names.map { |n| "`#{n}`" }
    end

    def base_copy_query(columns = nil)
      unless columns.nil?
        @base_copy_query  = nil
        columns = columns.map { |n| "`#{n}`" }
      else
        columns = quoted_column_names
      end
      
      @base_copy_query ||= %(INSERT INTO :new_table_name (#{columns.join(", ")}) SELECT #{columns.join(", ")} FROM :table_name)
    end

    def dry_run?
      config[:dry_run] == true
    end

    private

    def strategy
      # if change_table hasn't been called, this will use RawSqlStrategy
      @strategy ||= RawSqlStrategy.new(table, config, connection, base_copy_query, schema_changes)
    end

    def connection
      ActiveRecord::Base.connection
    end

    def engine
      CopyEngine.new(strategy)
    end
  end
end
