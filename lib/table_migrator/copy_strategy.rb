module TableMigrator
  class CopyStrategy

    attr_accessor :table, :config, :connection

    def initialize(table, config, connection)
      self.table      = table
      self.config     = config
      self.connection = connection
    end

    def new_table
    "new_#{table}"
    end

    def old_table
      if config[:migration_name]
      "#{table}_pre_#{config[:migration_name]}"
      else
      "#{table}_old"
      end
    end
    
    def column_names
      connection.columns(table).map {|c| c.name }
    end
  end
end
