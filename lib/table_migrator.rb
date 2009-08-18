module TableMigrator
  extend self

  def new(*args, &block)
    Base.new(*args, &block)
  end
end
