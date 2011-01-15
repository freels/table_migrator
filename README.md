# TableMigrator

Zero-downtime migrations of large tables in MySQL.

See the example for usage. Make sure you have an index on updated_at.

Install as a rails plugin: `./script/plugin install git://github.com/freels/table_migrator.git`


### What this does

TableMigrator is a method for altering large MySQL tables while incurring as little downtime as possible. There is nothing special about `ALTER TABLE`. All it does is create a new table with the new schema and copy over each row from the original table. Oh, and it does this in a big giant table lock, so you won't be using that big table for a while...

TableMigrator does essentially the same thing, but more intelligently. First, we create a new table like the original one, and then apply one or more `ALTER TABLE` statements to the unused, empty table. Second we copy all rows from the original table into the new one. All this time, reads and writes are going to the original table, so the two tables are not consistent. Finally, we acquire a write lock on the original table before copying over all new/changed rows, and swapping in the new table.

The solution to find updated or new rows is to use a column like `updated_at` (if a row is mutable) or `created_at` (if it is immutable) to determine which rows have been modified since the copy started. These rows are copied over to the new table using `REPLACE`.

If we do a single sweep of changed rows (you set `:multi_pass` to false), then a write lock is acquired before the sweep, new/changed rows are copied to the new table, the tables are swapped, and then the lock is released.

The default method (`:multi_pass => true`) copies over changed rows in a non-blocking manner multiple times until we can be reasonably sure that the final sweep will take very little time. The last sweep is done within the write lock, and then the tables are swapped. The length of time taken in the write lock is extremely short, hence the claim zero-downtime migration.

The key to making these sweeps for changes fast is to have an index on the column used to find them. Having an index on the relevant column makes this process fast. Without that index, TableMigrator eventually has to do a table scan within the final synchronous sweep, and that means downtime will be unavoidable.

### A note about DELETE

This method will not propagate normal `DELETES`s to the new table if they happen during/after the copy. In order to avoid this, use paranoid deletion, and update the column you are using to find changes appropriately.


## Examples

### Simple Migration

TableMigrator supports two APIs for defining migrations. One uses ActiveRecord's `change_table` syntax, and the other uses manually defined SQL snippets. You can create your migration by inheriting from TableMigration and skip some of the setup normally required.

Using change_table:

    class AddStuffToMyBigTable < TableMigration

      migrates :users
      # migrates also can take an options hash:
      #   :multi_pass        - See explanation above. Defaults to true
      #   :migration_name    - the original table is not dropped after the migration.
      #                        It will instead have a name based on this option.
      #                        The default is based on the migration class. (The old table
      #                        will end up named 'users_before_add_stuff_to_my_big_table'
      #                        in this case)
      #   :create_temp_table - Performs the migration in two steps if false. Read below
      #                        for details. Defaults to true.
      #   :dry_run           - If true, the migration will not actually run, just emit
      #                        fake progress to the log. Defaults to false.

      change_table do |t|
        t.integer :foo, :null => false, :default => 0
        t.string  :bar
        t.index   :foo, :name => 'index_for_foo'
      end
    end


Using raw sql:

    class AddStuffToMyBigTable < TableMigration
      migrates :users

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

      # some helpers are provided:
      #   table_migrator      - access to the TableMigrator instance being configured
      #   column_names        - defaults to an array of the original table's columns.
      #   quoted_column_names - the above, with each quoted in back-ticks.

      # you can also customize the base copy query by setting it to an INSERT statement
      # with no conditions. The default is based on column_names, above.
      # :table_name and :new_table_name are replaced with the original table and
      # new table names, respectively INSERT is substituted for REPLACE after the initial
      # bulk copy.
      table_migrator.base_copy_query = <<-SQL
        INSERT INTO :new_table_name (#{column_names.join(", ")}) 
        SELECT #{column_names.join(", ")} FROM :table_name
      SQL
    end


### Advanced Migration

You can use a normal ActiveRecord::Migration, you just have to set up a TableMigrator instance yourself. Otherwise, it works the same as above.

    class AddStuffToMyBigTable < ActiveRecord::Migration

      # just a helper method so we don't have to repeat this in self.up and self.down
      def self.setup

        # create a new TableMigrator instance for the table `users`
        # TableMigrator#initialize takes the same arguments as 'migrates'
        @tm = TableMigrator.new(:users,
          :migration_name => 'add_stuff',
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

        # customizing @tm.column_names
        @tm.column_names = %w(id name session password_hash created_at updated_at)

        # for convenience
        column_list = @tm.quoted_column_names.join(', ')

        # the base INSERT query with no wheres. (We'll take care of that part.)
        @tm.base_copy_query = <<-SQL
          INSERT INTO :new_table_name (#{column_list}) SELECT #{column_list} FROM :table_name
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


## Migrating in Two Phases

You can run the migration in two phases if you set the `:create_temp_table` option to false.

First, you deploy the code with the migration and manually run the `#create_table_and_copy_info` method:

    # if you use a TableMigration sublcass
    >> require 'db/migrate/13423423_my_migration.rb'
    >> now = Time.now
    >> MyMigration.create_table_and_copy_info
    >> puts %(NEXT_EPOCH="#{now}")
    NEXT_EPOCH="Tue Feb 16 13:22:14 -0800 2010"

This creates the temporary table, copies the data over without locking anything.  You can safely run this without halting your application.

Finally, you put up whatever downtime notices you have and run your typical migration task.  Since the table is already created, the script will only
copy data (if multi_pass is enabled) and perform the actual table move.  It assumes the temporary table has been created already.

    $ NEXT_EPOCH="Tue Feb 16 13:22:14 -0800 2010" RAILS_ENV=production rake db:migrate

## Contributors
- Matt Freels
- Rohith Ravi
- Rick Olson

Copyright (c) 2009 Serious Business, released under the MIT license.
