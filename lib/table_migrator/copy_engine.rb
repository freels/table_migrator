module TableMigrator
  class CopyEngine

    attr_accessor :strategy

    # magic numbers
    MAX_DELTA_PASSES = 5
    DELTA_CONTINUE_THRESHOLD = 5
    PAGE_SIZE = 50_000
    DELTA_PAGE_SIZE = 1000
    PAUSE_LENGTH = 5

    def initialize(strategy)
      self.strategy = strategy 

      #updated_at sanity check
      unless dry_run? or strategy.column_names.include?(delta_column.to_s)
        raise "Cannot use #{self.class.name} on #{table_name.inspect} table without a delta column: #{delta_column.inspect}"
      end
    end

    def up!
      info 'Executing dry run...' if dry_run?

      self.create_new_table if create_temp_table?

      # is there any data to copy?
      if dry_run? or execute("SELECT * FROM `#{table_name}` LIMIT 1").fetch_row

        # copy bulk of table data
        self.paged_copy if create_temp_table?

        # multi-pass delta copy to reduce the size of the locked pass
        self.multi_pass_delta_copy if multi_pass?

        if create_temp_table? || multi_pass?
          # wait here...
          info "Waiting for #{PAUSE_LENGTH} seconds"
          PAUSE_LENGTH.times { info '.'; $stdout.flush; sleep 1 }
          info ' '
        end

        # lock for write, copy final delta, and swap
        in_table_lock(table_name, new_table_name) do
          self.full_delta_copy
          execute("ALTER TABLE `#{table_name}` RENAME TO `#{old_table_name}`")
          execute("ALTER TABLE `#{new_table_name}` RENAME TO `#{table_name}`")
        end

      else
        # if there are no rows previously, lock and copy everything (probably still nothing).
        # this will not be the case in production.
        in_table_lock(table_name, new_table_name) do
          execute(self.base_copy_query)
          execute("ALTER TABLE `#{table_name}` RENAME TO `#{old_table_name}")
          execute("ALTER TABLE `#{new_table_name}` RENAME TO `#{table_name}`")
        end
      end
    end

    def down!
      in_table_lock(table_name, old_table_name) do
        execute("ALTER TABLE `#{table_name}` RENAME TO `#{new_table_name}`")
        execute("ALTER TABLE `#{old_table_name}` RENAME TO `#{table_name}`")
        execute("DROP TABLE `#{new_table_name}`")
      end
    end

    # performs only the table creation and copy phases so that the actual migration
    # is as quick as possible.
    def create_table_and_copy_info
      create_new_table
      paged_copy
      multi_pass_delta_copy if multi_pass?
    end


    # migration steps
    def create_new_table
      execute("CREATE TABLE `#{new_table_name}` LIKE `#{table_name}`")

      # make schema changes
      info "Applying schema changes to new table"
      strategy.apply_changes unless dry_run?
    end

    def paged_copy
      info "Copying #{table_name} to #{new_table_name}"

      # record start of this epoch
      self.flop_epoch

      start = 0
      page = 0
      loop do
        info "page #{page += 1}..."
        execute(paged_copy_query(start, PAGE_SIZE))

        new_start = if dry_run?
          0
        else
          select_all("select max(id) from `#{new_table_name}`").first.values.first.to_i
        end

        break if start == new_start
        start = new_start
      end
    end

    def multi_pass_delta_copy
      info "Multi-pass non-locking delta copy from #{table_name} to #{new_table_name}"

      pass = 0
      loop do
        info "pass #{pass += 1}..."

        time_start = Time.now
        self.paged_delta_copy
        time_elapsed = Time.now.to_i - time_start.to_i

        break if time_elapsed <= DELTA_CONTINUE_THRESHOLD or pass == MAX_DELTA_PASSES
      end
    end

    def paged_delta_copy
      epoch = self.flop_epoch
      updated_ids = select_all(updated_ids_query(epoch)).map{|r| r['id'].to_i}

      updated_ids.in_groups_of(DELTA_PAGE_SIZE, false) do |ids|
        info "Executing: #{paged_delta_copy_query(['IDS'])}"
        execute(paged_delta_copy_query(ids), true)
      end
    end

    def full_delta_copy
      epoch = self.last_epoch
      info_with_time "Copying delta from #{table_name} to #{new_table_name}" do
        execute(full_delta_copy_query(epoch))
      end
    end

    # Logging

    def info(str)
      ActiveRecord::Migration.say(str)
    end

    def info_with_time(str, &block)
      ActiveRecord::Migration.say_with_time(str, &block)
    end

    # Manage the Epoch

    def flop_epoch
      epoch = @next_epoch
      @next_epoch = self.next_epoch
      info "Current Epoch starts at: #{@next_epoch}"
      epoch
    end

    def last_epoch
      @next_epoch
    end

    def next_epoch
      return Time.at(0) if dry_run?

      epoch_query = "SELECT `#{delta_column}` FROM `#{table_name}`
      ORDER BY `#{delta_column}` DESC LIMIT 1"

      select_all(epoch_query).first[delta_column]
    end


    # Queries

    def base_copy_query
      strategy.base_copy_query('REPLACE')
    end

    def paged_copy_query(start, limit)
    "#{base_copy_query} WHERE `id` > #{start} LIMIT #{limit}"
    end

    def full_delta_copy_query(epoch)
    "#{base_copy_query} WHERE `#{delta_column}` >= '#{epoch}'"
    end

    def updated_ids_query(epoch)
    "SELECT `id` FROM #{table_name} WHERE `#{delta_column}` >= '#{epoch}'"
    end

    def paged_delta_copy_query(ids)
    "#{base_copy_query} WHERE `id` in (#{ids.join(', ')})"
    end


    # Config Helpers

    def delta_column
      strategy.config[:delta_column]
    end

    def table_name
      strategy.table
    end

    def new_table_name
      strategy.new_table
    end

    def old_table_name
      strategy.old_table
    end

    # behavior

    def dry_run?
      strategy.config[:dry_run] == true
    end

    def create_temp_table?
      strategy.config[:create_temp_table] == true
    end

    def multi_pass?
      strategy.config[:multi_pass] == true
    end


    # SQL Execution

    def execute(sql, quiet = false)
      execution = lambda do
        unless dry_run?
          strategy.connection.execute(sql)
        end
      end
      if quiet
        execution.call
      else
        info_with_time("Executing: #{sql}", &execution)
      end
    end

    def select_all(sql, quiet = false)
      execution = lambda do
        if dry_run?
          []
        else
          strategy.connection.select_all(sql)
        end
      end
      if quiet
        execution.call
      else
        info_with_time("Finding: #{sql}", &execution)
      end
    end

    def in_table_lock(*tables)
      info_with_time "Acquiring write lock." do
        begin
          execute('SET autocommit=0')
          table_locks = tables.map {|t| "`#{t}` WRITE"}.join(', ')
          execute("LOCK TABLES #{table_locks}")

          yield

          execute('COMMIT')
          execute('UNLOCK TABLES')
        ensure
          execute('SET autocommit=1')
        end
      end
    end
  end
end
