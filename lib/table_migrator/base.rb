module TableMigrator
  class Base
    attr_accessor :strategy, :engine

    def initialize(table, config = {}, &block)
      if config.delete(:raw)
        self.strategy = SqlStatementsStrategy.new
        yield(strategy)
      else
        connection = ActiveRecord::Base.connection
        self.strategy = ChangeTableStrategy.new(table, connection, &block)
      end

      self.engine = CopyEngine.new(table, strategy, config)
    end

    def up!
      engine.up!
    end

    def down!
      engine.down!
    end
  end
end
