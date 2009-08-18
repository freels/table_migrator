# TableMigrator

by Matt Freels and Rohith Ravi


Zero-downtime migrations of large tables in MySQL. 

See the example for usage. Make sure you have an index on updated_at.

Install as a rails plugin:

    ./script/plugin install git://github.com/freels/table_migrator.git


### What this does

TableMigrator is a strategy for altering large MySQL tables while incurring as little downtime as possible. There is nothing special about ALTER TABLE. All it does is create a new table with the new schema and copy over each row from the original table. Oh, and it does this in a big giant table lock, so you won't be using that big table for a while...

TableMigrator does essentially the same thing as ALTER TABLE, but more intelligently, since we can be more intelligent when we know something about the data being copied. First, we create a new table like the original one, and then apply one or more ALTER TABLE statements to the unused, empty table. Second we copy all rows from the original table into the new one. All this time, reads and writes are going to the original table, so the two tables are not consistent. 

The solution to find updated or new rows is to use updated_at (if a row is mutable) or created_at (if it is immutable) to determine which rows have been modified since the copy started. Those rows are copied over to the new table using an INSERT TABLE sequence with an ON DUPLICATE KEY clause.

If we are doing a single delta pass (you set :multi_pass to false), then a write lock is acquired before the delta copy, the delta is copied to the new table, the tables are swapped, and then the lock is released.

The :multi_pass version does the same thing above but copies the delta in a non-blocking manner multple times until the length if time taken is small enough. Finally, the last delta copy is done synchronously, and the tables are swapped. Usually the delta left for this last copy is extremely small. Hence the claim zero-downtime migration.

The key to the multi_pass version is having an index on created_at or updated_at. Having an index on the relevant field makes looking up the delta much faster. Without that index, TableMigrator has to do a table scan while holding the table write lock, and that means you are definitely going to incur downtime.

## Example Migration (shortcut)

You can create your migration by inheriting from TableMigration and skip some of the setup required for the TableMigrator.

    class AddAColumnToMyGigantoTable < TableMigration
      migrates :users, 
        :multi_pass => true,
        # assumed, feel free to specify if you so desire
        # :migration_name => 'add_a_column_to_my_giganto_table',
        :create_temp_table => true, # default
        :dry_run => false

      # push alter tables to schema_changes
      schema_changes.push <<-SQL
        ALTER TABLE :new_table_name 
        ADD COLUMN `foo` int(11) unsigned NOT NULL DEFAULT 0
      SQL

      schema_changes.push <<-SQL
        ALTER TABLE :new_table_name 
        ADD COLUMN `bar` varchar(255)
      SQL

      schema_changes.push <<-SQL
        ALTER TABLE :new_table_name 
        ADD INDEX `index_foo` (`foo`)
      SQL

      # This is queried from the table for you
      table_migrator.column_names = %w(id name session password_hash created_at updated_at)

      # the base INSERT query with no wheres. (This is generated for you based on the column names above)
      table_migrator.base_copy_query = <<-SQL
        INSERT INTO :new_table_name (#{column_names.join(", ")}) 
        SELECT #{column_names.join(", ")} FROM :table_name
      SQL

      # specify the ON DUPLICATE KEY update strategy. (This is generated for you based on the column names above)
      table_migrator.on_duplicate_update_map = <<-SQL
        #{column_names.map {|c| "#{c}=VALUES(#{c})"}.join(", ")}
      SQL
    end

## Example Migration (explicit)

    class AddAColumnToMyGigantoTable < ActiveRecord::Migration

      # just a helper method so we don't have to repeat this in self.up and self.down
      def self.setup

        # create a new TableMigrator instance for the table `users`
        # :migration_name - a label for this migration, used to rename old tables.
        #                   this must be unique for each migration using a TableMigrator
        # :multi_pass     - copy the delta asynchronously multiple times.
        # :dry_run        - set to false to really run the tm's SQL.
        @tm = TableMigrator.new("users",
          :migration_name => 'random_column',
          :multi_pass => true,
          :create_temp_table => true, # default
          :dry_run => false
        )
        
        # push alter tables to schema_changes
        @tm.schema_changes.push <<-SQL
          ALTER TABLE :new_table_name 
          ADD COLUMN `foo` int(11) unsigned NOT NULL DEFAULT 0
        SQL

        @tm.schema_changes.push <<-SQL
          ALTER TABLE :new_table_name 
          ADD COLUMN `bar` varchar(255)
        SQL

        @tm.schema_changes.push <<-SQL
          ALTER TABLE :new_table_name 
          ADD INDEX `index_foo` (`foo`)
        SQL

        # for convenience
        common_cols = %w(id name session password_hash created_at updated_at)    

        # the base INSERT query with no wheres. (We'll take care of that part.)
        @tm.base_copy_query = <<-SQL
          INSERT INTO :new_table_name (#{common_cols.join(", ")}) 
          SELECT #{common_cols.join(", ")} FROM :table_name
        SQL

        # specify the ON DUPLICATE KEY update strategy.
        @tm.on_duplicate_update_map = <<-SQL
          #{common_cols.map {|c| "#{c}=VALUES(#{c})"}.join(", ")}
        SQL
      end
      
      def self.up
        self.setup    
        @tm.up!
      end

      def self.down
        self.setup    
        @tm.down!
      end

      # see 'two-phase migration' below
      def self.create_table_and_copy_info
        self.setup
        @tm.create_table_and_copy_info
      end
    end

# Two-phase migration

You can run the migration in two phases if you set the `:create_temp_table` option to false.

First, you deploy the code with the migration and manually run the `#create_table_and_copy_info` method:

    # if you use a TableMigration sublcass
    >> require 'db/migrate/13423423_my_migration.rb'
    >> MyMigration.create_table_and_copy_info

This creates the temporary table, copies the data over without locking anything.  You can safely run this without halting your application.

Finally, you put up whatever downtime notices you have and run your typical migration task.  Since the table is already created, the script will only
copy data (if multi_pass is enabled) and perform the actual table move.  It assumes the temporary table has been created already.

Thanks go to the rest of the crew at SB.


Copyright (c) 2009 Serious Business, released under the MIT license
