require 'table_migration'
require 'table_migrator/base'

module TableMigrator
  extend self

  def new(*args, &block)
    Base.new(*args, &block)
  end
end
