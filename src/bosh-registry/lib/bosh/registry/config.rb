module Bosh::Registry

  class << self

    attr_accessor :logger
    attr_accessor :http_port
    attr_accessor :db
    attr_accessor :instance_manager
    attr_accessor :auth

    def configure(config)
      validate_config(config)

      @logger ||= Logger.new(config["logfile"] || STDOUT)
      if config["loglevel"].kind_of?(String)
        @logger.level = Logger.const_get(config["loglevel"].upcase)
      end

      @http_port = config["http"]["port"]

      @auth = []

      if config['http']['user']        
        @auth << {
            'username' => config['http']['user'],
            'password' => config['http']['password']
        }
      else

        @auth = config['http']['auth']
      end

      @db = connect_db(config["db"])

      if config.has_key?("cloud")
        plugin = config["cloud"]["plugin"]
        begin
          require "bosh/registry/instance_manager/#{plugin}"
        rescue LoadError
          raise ConfigError, "Could not find Provider Plugin: #{plugin}"
        end
        @instance_manager = Bosh::Registry::InstanceManager.const_get(plugin.capitalize).new(config["cloud"])
      else
        @instance_manager = Bosh::Registry::InstanceManager.new
      end
    end

    def connect_db(db_config)
      connection_options = db_config.delete('connection_options') {{}}
      db_config.delete_if { |_, v| v.to_s.empty? }
      db_config = db_config.merge(connection_options)

      db = Sequel.connect(db_config)
      if logger
        db.logger = @logger
        db.sql_log_level = :debug
      end

      db
    end

    def validate_config(config)
      unless config.is_a?(Hash)
        raise ConfigError, "Invalid config format, Hash expected, " \
                           "#{config.class} given"
      end

      unless config.has_key?("http") && config["http"].is_a?(Hash)
        raise ConfigError, "HTTP configuration is missing from config file"
      end

      unless config.has_key?("db") && config["db"].is_a?(Hash)
        raise ConfigError, "Database configuration is missing from config file"
      end

      if config.has_key?("cloud")
        unless config["cloud"].is_a?(Hash)
          raise ConfigError, "Cloud configuration is missing from config file"
        end

        if config["cloud"]["plugin"].nil?
          raise ConfigError, "Cloud plugin is missing from config file"
        end
      end
    end

  end
end