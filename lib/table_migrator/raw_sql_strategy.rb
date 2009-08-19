module TableMigrator
  class RawSqlStrategy
    attr_accessor :base_copy_query, :schema_changes

    def initialize(table, config, connection, base_copy_query, schema_changes)
      super(table, config, connection)

      self.base_copy_query = base_copy_query
      self.schema_changes  = schema_changes
    end

    def apply_changes
      schema_changes.each do |sql|
        connection.execute sub_new_table(sql, new_table)
      end
    end

    # columns are the responsibility of the user
    def base_copy_query(insert_or_replace)
      copy = base_copy_query.gsub(/\A\s*INSERT/i, insert_or_replace)
      copy = sub_new_table(copy, new_table)
      copy = sub_table(copy, table)
      copy
    end

    private

    def sub_table(sql, table)
      sql.to_s.gsub(":table_name", "`#{table}`")
    end

    def sub_new_table(sql, new_table)
      sql.to_s.gsub(":new_table_name", "`#{new_table}`")
    end
  end
end
