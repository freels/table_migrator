module TableMigrator
  class SqlStatementsStrategy
    attr_accessor :base_copy_query

    def schema_changes
      @schema_changes ||= []
    end

    def apply_changes(connection, new_table)
      schema_changes.each do |sql|
        connection.execute sub_new_table(sql, new_table)
      end
    end

    # columns are the responsibility of the user
    def copy_sql_for(insert_or_replace, table, new_table, columns)
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
