module Database
  class Base
    attr_accessor :config, :output_file
    def initialize(cap_instance)
      @cap = cap_instance
    end

    def mysql?
      @config['adapter'] =~ /^mysql/
    end

    def postgresql?
      %w(postgresql pg).include? @config['adapter']
    end

    def credentials
      if mysql?
        username = @config['username'] || @config['user']
        (username ? " -u #{username} " : '') + (@config['password'] ? " -p'#{@config['password']}' " : '') + (@config['host'] ? " -h #{@config['host']}" : '') + (@config['socket'] ? " -S#{@config['socket']}" : '')
      elsif postgresql?
        (@config['username'] ? " -U #{@config['username']} " : '') + (@config['host'] ? " -h #{@config['host']}" : '')
      end
    end

    def database
      @config['database']
    end

    def current_time
      Time.now.strftime("%Y-%m-%d-%H%M%S")
    end

    def output_file
      @output_file ||= "db/#{database}_#{current_time}.sql.bz2"
    end

    def pgpass
      "PGPASSWORD='#{@config['password']}'" if @config['password']
    end

  private

    def dump_cmd
      if mysql?
        "mysqldump #{credentials} #{database} --single-transaction --lock-tables=false | grep -v '50013 DEFINER'"
      elsif postgresql?
        "#{pgpass} pg_dump --no-acl --no-owner #{credentials} #{database}"
      end
    end

    def import_cmd(file)
      if mysql?
        "mysql #{credentials} -D #{database} < #{file}"
      elsif postgresql?
        terminate_connection_sql = "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '#{database}' AND pid <> pg_backend_pid();"
        "#{pgpass} psql -c \"#{terminate_connection_sql};\" #{credentials}; #{pgpass} dropdb #{credentials} #{database}; #{pgpass} createdb #{credentials} #{database}; #{pgpass} psql #{credentials} -d #{database} < #{file}"
      end
    end

  end

  class Remote < Base
    def initialize(cap_instance)
      super(cap_instance)
      @config = @cap.capture("cat #{@cap.shared_path}/config/database.yml")
      @config = YAML.load(ERB.new(@config).result)[@cap.fetch(:rails_env).to_s]
    end

    def dump
      @cap.execute "cd #{@cap.release_path} && #{dump_cmd} | bzip2 - - > #{output_file}"
      self
    end

    def download(local_file = "#{output_file}")
      remote_file = "#{@cap.release_path}/#{output_file}"
      @cap.download! remote_file, local_file
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, '.bz2'))
      # @cap.run "cd #{@cap.current_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.rails_env} bundle exec rake db:drop db:create && #{import_cmd(unzip_file)}"
      @cap.execute "cd #{@cap.release_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.fetch(:rails_env)} && #{import_cmd(unzip_file)}"
      @cap.execute("cd #{@cap.release_path} && rm #{unzip_file}") if cleanup
    end
  end
  
  class RemoteRo < Remote
    
    def initialize(cap_instance, opts = {})
      super(cap_instance)
      
      if _env = opts[:source_env]
        @config = @cap.capture("cat #{@cap.shared_path}/config/database.yml")
        @config = YAML.load(ERB.new(@config).result)[_env.to_s]
      else
        @config['database'] = opts[:database]
        @config['username'] = opts[:username]
        @config['password'] = opts[:password]
        @config['host'] = opts[:host]
      end
    end
    
    def load
      raise 'remote database is read only'
    end
  end
  
  class Local < Base
    def initialize(cap_instance)
      super(cap_instance)
      @config = YAML.load(ERB.new(File.read(File.join('config', 'database.yml'))).result)[fetch(:local_rails_env).to_s]
      puts "local #{@config}"
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, '.bz2'))
      # system("bunzip2 -f #{file} && bundle exec rake db:drop db:create && #{import_cmd(unzip_file)} && bundle exec rake db:migrate")
      @cap.info "executing local: bunzip2 -f #{file} && #{import_cmd(unzip_file)}"
      system("bunzip2 -f #{file} && #{import_cmd(unzip_file)}")
      if cleanup
        @cap.info "removing #{unzip_file}"
        File.unlink(unzip_file)
      else
        @cap.info "leaving #{unzip_file} (specify :db_local_clean in deploy.rb to remove)"
      end
      @cap.info "Completed database import"
    end

    def dump
      system "#{dump_cmd} | bzip2 - - > #{output_file}"
      self
    end

    def upload
      remote_file = "#{@cap.release_path}/#{output_file}"
      @cap.upload! output_file, remote_file
    end
  end


  class << self
    def check(local_db, remote_db)
      unless (local_db.mysql? && remote_db.mysql?) || (local_db.postgresql? && remote_db.postgresql?)
        raise 'Only mysql or postgresql on remote and local server is supported'
      end
    end

    def remote_to_local(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      remote_db.dump.download
      local_db.load(remote_db.output_file, instance.fetch(:db_local_clean))
    end

    def local_to_remote(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      local_db.dump.upload
      remote_db.load(local_db.output_file, instance.fetch(:db_local_clean))
    end
    
    def remote_to_remote(instance, opts = {})
      destination_db = Database::Remote.new(instance)
      source_db = Database::RemoteRo.new(instance, opts)
      
      check(destination_db, source_db)
      
      source_db.dump
      destination_db.load(source_db.output_file, instance.fetch(:db_local_clean))
    end
    
  end

end
