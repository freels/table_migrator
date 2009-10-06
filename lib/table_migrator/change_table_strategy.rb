module TableMigrator

  class ChangeTableStrategy < CopyStrategy
    attr_accessor :changes, :renames

    class TableNameMismatchError < Exception; end

    def initialize(table, config, connection)
      super(table, config, connection)

      @changes = []
      @renames = Hash.new {|h,k| h[k.to_s] = k.to_s }

      yield ::ActiveRecord::ConnectionAdapters::Table.new(table, self)
    end

    # interface used by Base.

    def apply_changes
      changes.each do |method, args|
        connection.send(method, new_table, *args)
      end
    end

    def base_copy_query(insert_or_replace)
      copied = column_names.reject {|c| renames[c].nil? }
      renamed = copied.map {|c| renames[c] }
      renamed = renamed.map {|c| "`#{c}`"}
      copied = copied.map {|c| "`#{c}`"}

      "#{insert_or_replace} INTO `#{new_table}` (#{renamed.join(', ')})
        SELECT #{copied.join(', ')} FROM `#{table}`"
    end


    # delegate methods used for table introspection to the native connection

    def type_to_sql(*args);           connection.type_to_sql(*args); end
    def quote_column_name(*args);     connection.quote_column_name(*args); end
    def add_column_options!(*args);   connection.add_column_options!(*args); end
    def native_database_types(*args); connection.native_database_types(*args); end


    # change registration callbacks

    def method_missing(method, table_name, *args)
      if table_name != @table
        raise TableNameMismatchError, "Expected table `#{@table}`, got `#{table_name}`!"
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

    def register_remove_column(*columns)
      columns.each do |col|
        renames[col.to_s] = nil
      end
    end

    def register_remove_timestamps
      register_remove_column :created_at, :updated_at
    end
  end
end
