module TableMigrator

  class ChangeTableStrategy
    attr_accessor :changes, :renames, :connection

    class TableNameMismatchError < Exception; end

    def initialize(table_name, connection)
      @table_name = table_name
      @connection = connection
      @changes = []
      @renames = Hash.new {|h,k| h[k.to_s] = k.to_s }

      yield ::ActiveRecord::ConnectionAdapters::Table.new(table_name, self)
    end

    # interface used by Base.

    def apply_changes(connection, table_name)
      changes.each do |method, args|
        connection.send(method, table_name, *args)
      end
    end

    def copy_sql_for(insert_or_replace, from_table, to_table, columns)
      p columns
      p renames
      copied = columns.reject {|c| renames[c].nil? }
      renamed = copied.map {|c| renames[c] }

      "#{insert_or_replace} INTO #{to_table} (#{renamed.join(', ')})
        SELECT #{copied.join(', ')} FROM #{from_table}"
    end


    # delegate methods used for table introspection to the native connection

    def type_to_sql(*args);           connection.type_to_sql(*args); end
    def quote_column_name(*args);     connection.quote_column_name(*args); end
    def add_column_options!(*args);   connection.add_column_options!(*args); end
    def native_database_types(*args); connection.native_database_types(*args); end


    # change registration callbacks

    def method_missing(method, table_name, *args)
      if table_name != @table_name
        raise TableNameMismatchError, "Expected table `#{@table_name}`, got `#{table_name}`!"
      end

      # register the change if we need to do something special during the copy phase.
      send("register_#{method}", *args) if respond_to?("register_#{method}")

      # record for replay later
      changes << [method, args]
    end

    def register_rename_column(col, new_name)
      puts "rename called"
      renames[col.to_s] = new_name.to_s
    end

    def register_remove_column(*column_names)
      column_names.each do |col|
        renames[col.to_s] = nil
      end
    end

    def register_remove_timestamps
      register_remove_column :created_at, :updated_at
    end
  end
end
