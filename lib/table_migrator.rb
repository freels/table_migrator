class TableMigrator
  attr_accessor :table_name, :old_table_name
  attr_accessor :schema_changes, :base_copy_query, :on_duplicate_update_map, :column_names, :quoted_column_names
  attr_accessor :config

  # magic numbers
  MAX_DELTA_PASSES = 5
  DELTA_CONTINUE_THRESHOLD = 5
  PAGE_SIZE = 50_000
  DELTA_PAGE_SIZE = 1000
  PAUSE_LENGTH = 5

  def initialize(table_name, config = {})
    self.table_name     = table_name
    self.schema_changes = []
    @column_names = @quoted_column_names = @base_copy_query = @on_duplicate_update_map = nil

    defaults = { :dry_run => true }
    self.config = defaults.merge(config)

    #updated_at sanity check
    unless dry_run? or column_names.include?(delta_column.to_s)
      raise "Cannot use #{self.class.name} on #{table_name.inspect} table without a delta column: #{delta_column.inspect}"
    end
  end

  def column_names
    @column_names ||= ActiveRecord::Base.connection.columns(@table_name).map { |c| c.name }
  end

  def quoted_column_names
    @quoted_column_names ||= column_names.map { |n| "`#{n}`" }
  end

  def base_copy_query(columns = nil)
    @base_copy_query   = nil unless columns.nil?
    columns          ||= quoted_column_names
    @base_copy_query ||= %(INSERT INTO :new_table_name (#{columns.join(", ")}) SELECT #{columns.join(", ")} FROM :table_name)
  end

  def on_duplicate_update_map(columns = nil)
    @on_duplicate_update_map   = nil unless columns.nil?
    columns                  ||= quoted_column_names
    @on_duplicate_update_map ||= %(#{common_cols.map {|c| "#{c}=VALUES(#{c})"}.join(", ")})
  end

  def up!
    info (dry_run? ? 'Executing dry run...' : 'Executing forealz...')

    self.create_new_table

    # is there any data to copy?
    if dry_run? or execute('SELECT * FROM :table_name LIMIT 1').fetch_row

      # copy bulk of table data
      self.paged_copy

      # multi-pass delta copy to reduce the size of the locked pass
      self.multi_pass_delta_copy if multi_pass?

      # wait here...
      info "Waiting for #{PAUSE_LENGTH} seconds"
      PAUSE_LENGTH.times { info '.'; $stdout.flush; sleep 1 }
      info ' '

      # lock for write, copy final delta, and swap
      in_table_lock(table_name, new_table_name) do
        self.full_delta_copy
        execute("ALTER TABLE `#{table_name}` RENAME TO `#{old_table_name}")
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

  # migration steps

  def create_new_table
    execute("CREATE TABLE :new_table_name LIKE :table_name")

    # make schema changes
    unless self.schema_changes.blank?
      self.schema_changes.each do |sql|
        execute(sql)
      end
    end
  end

  def paged_copy
    info "Copying :table_name to :new_table_name."
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
        select_all("select max(id) from :new_table_name").first.values.first.to_i
      end

      break if start == new_start
      start = new_start
    end
  end

  def multi_pass_delta_copy
    info "Multi-pass non-locking delta copy from :table_name to :new_table_name"

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
    info "Copying delta from :table_name to :new_table_name" do
      execute(full_delta_copy_query(epoch))
    end
  end

  def info(str)
    ActiveRecord::Migration.say(prepare_sql(str))
  end

  def info_with_time(str, &block)
    ActiveRecord::Migration.say_with_time(prepare_sql(str), &block)
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
    epoch_query = "SELECT `#{delta_column}` FROM `#{table_name}`
      ORDER BY `#{delta_column}` DESC LIMIT 1"

    if dry_run?
      select_all(epoch_query)
      Time.now.utc
    else
      select_all(epoch_query).first[delta_column]
    end
  end


  # Derived Queries

  def paged_copy_query(start, limit)
    "#{base_copy_query} WHERE `id` > #{start} LIMIT #{limit}"
  end

  def full_delta_copy_query(epoch)
    "#{base_copy_query} WHERE `#{delta_column}` >= '#{epoch}'
      ON DUPLICATE KEY UPDATE #{on_duplicate_update_map}"
  end

  def updated_ids_query(epoch)
    "SELECT `id` FROM #{table_name} WHERE `#{delta_column}` >= '#{epoch}'"
  end

  def paged_delta_copy_query(ids)
    "#{base_copy_query} WHERE `id` in (#{ids.join(', ')})
      ON DUPLICATE KEY UPDATE #{on_duplicate_update_map}"
  end


  # Config Helpers

  # query

  def delta_column
    config[:delta_column] || "updated_at"
  end

  def new_table_name
    "new_#{table_name}"
  end

  def old_table_name
    if config[:migration_name]
      "#{table_name}_pre_#{config[:migration_name]}"
    else
      "old#{table_name}"
    end
  end

  # behavior

  def dry_run?
    config[:dry_run] == true
  end

  def multi_pass?
    config[:multi_pass] == true
  end


  # SQL Execution

  def prepare_sql(sql)
    sql.to_s.
      gsub(":table_name", "`#{table_name}`").
      gsub(":old_table_name", "`#{old_table_name}`").
      gsub(":new_table_name", "`#{new_table_name}`")
  end

  def execute(sql, quiet = false)
    execution = lambda do 
      unless dry_run?
        ActiveRecord::Base.connection.execute(prepare_sql(sql))
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
        ActiveRecord::Base.connection.select_all(prepare_sql(sql))
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
      execute('SET autocommit=0')
      table_locks = tables.map {|t| "`#{t}` WRITE"}.join(', ')
      execute("LOCK TABLES #{table_locks}")

      yield

      execute('COMMIT')
      execute('UNLOCK TABLES')
      execute('SET autocommit=1')
    end
  end

  def in_global_lock
    info_with_time "Acquiring global lock" do
      execute('FLUSH TABLES WITH READ LOCK')
      yield
      execute('UNLOCK TABLES')
    end
  end
end
