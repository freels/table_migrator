module TableMigrator
  class MigrationStrategy
    attr_accessor :changes, :renames

    class TableNameMismatchError < Exception; end

    def initialize(table_name)
      @table_name = table_name
      @changes = []
      @renames = Hash.new {|h,k| h[k] = k.to_s }.with_indifferent_access

      yield ::ActiveRecord::ConnectionAdapters::Table.new(table_name, self)
    end

    def register_change(method, table_name, *args)
      if table_name != @table_name
        raise TableNameMismatchError, "Expected table `#{@table_name}`, got `#{table_name}`!"
      end

      # register the change if we need to do something special
      # during the copy phase.
      send(method, *args) if respond_to?(method)

      # record for replay later
      changes << [method, *args]
    end
    alias method_missing register_change

    def replay_changes(connection, table_name)
      changes.each do |method, args|
        connection.send(method, table_name, *args)
      end
    end

    def copy_sql_for(insert_or_replace, from_table, to_table, columns)
      copied = columns.reject {|c| renames[c].nil? }
      renamed = copied.map {|c| renames[c] }

      "#{insert_or_replace} INTO #{to_table} (#{renamed.join(', ')})
        SELECT #{copied.join(', ')} FROM #{from_table}"
    end

    private

    # connection adapter masking

    def rename_column(col, new_name)
      renames[col] = new_name.to_s
    end

    def remove_column(*column_names)
      column_names.each do |col|
        renames[col] = nil
      end
    end

    def remove_timestamps
      remove_column :created_at, :updated_at
    end
  end
end
