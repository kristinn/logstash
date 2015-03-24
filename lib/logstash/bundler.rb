require "logstash/environment"

module LogStash
  module Bundler

    def self.setup!(options = {})
      options = {:without => [:development]}.merge(options)
      options[:without] = Array(options[:without])

      # make sure we use our own installed bundler
      require "logstash/patches/rubygems" # patch rubygems before clear_paths
      ::Gem.clear_paths
      ::Gem.paths = ENV['GEM_HOME'] = ENV['GEM_PATH'] = LogStash::Environment.logstash_gem_home

      # set BUNDLE_GEMFILE ENV before requiring bundler to avoid bundler recurse and load unrelated Gemfile(s)
      ENV["BUNDLE_GEMFILE"] = LogStash::Environment::GEMFILE_PATH

      require "bundler"
      require "logstash/bundler"
      require "logstash/patches/bundler"

      ::Bundler.settings[:path]    = LogStash::Environment::BUNDLE_DIR
      ::Bundler.settings[:without] = options[:without].join(":")
      # in the context of Bundler.setup it looks like this is useless here because Gemfile path can only be specified using
      # the ENV, see https://github.com/bundler/bundler/blob/v1.8.3/lib/bundler/shared_helpers.rb#L103
      ::Bundler.settings[:gemfile] = LogStash::Environment::GEMFILE_PATH

      ::Bundler.reset!
      ::Bundler.setup
    end

    # capture any $stdout from the passed block. also trap any exception in that block, in which case the trapped exception will be returned
    # @param [Proc] the code block to execute
    # @return [String, Exception] the captured $stdout string and any trapped exception or nil if none
    def self.capture_stdout(&block)
      old_stdout = $stdout
      $stdout = StringIO.new("", "w")
      begin
        block.call
      rescue => e
        return [$stdout.string, e]
      end

      [$stdout.string, nil]
    ensure
      $stdout = old_stdout
    end

    # execute bundle install and capture any $stdout output. any raised exception in the process will be trapped
    # and returned. logs errors to $stdout.
    # @param options [Hash] invoke options with default values, :max_tries => 10, :clean => false, :install => false, :update => false
    # @param   options[:update] must be either false or a String or an Array of String
    # @return [String, Exception] the installation captured output and any raised exception or nil if none
    def self.invoke_bundler!(options = {})
      options = {:max_tries => 10, :clean => false, :install => false, :update => false, :without => [:development]}.merge(options)
      options[:without] = Array(options[:without])
      options[:update] = Array(options[:update]) if options[:update]

      # make sure we use our own installed bundler
      require "logstash/patches/rubygems" # patch rubygems before clear_paths
      ::Gem.clear_paths
      ::Gem.paths = ENV['GEM_HOME'] = ENV['GEM_PATH'] = LogStash::Environment.logstash_gem_home

      # set BUNDLE_GEMFILE ENV before requiring bundler to avoid bundler recurse and load unrelated Gemfile(s).
      # in the context of calling Bundler::CLI this is not really required since Bundler::CLI will look at
      # Bundler.settings[:gemfile] unlike Bundler.setup. For the sake of consistency and defensive/future proofing, let's keep it here.
      ENV["BUNDLE_GEMFILE"] = LogStash::Environment::GEMFILE_PATH

      require "bundler"
      require "bundler/cli"
      require "logstash/patches/bundler"

      ::Bundler.settings[:path] = LogStash::Environment::BUNDLE_DIR
      ::Bundler.settings[:gemfile] = LogStash::Environment::GEMFILE_PATH
      ::Bundler.settings[:without] = options[:without].join(":")
      ::Bundler.settings[:cache_path] = "#{Pathname.new(::Bundler.settings.path).relative_path_from(Pathname.new(LogStash::Environment::LOGSTASH_HOME))}/cache"

      try = 0

      # capture_stdout also traps any raised exception and pass them back as the function return [output, exception]
      capture_stdout do
        loop do
          begin
            ::Bundler.reset!
            ::Bundler::CLI.start(bundler_arguments(options))
            break
          rescue ::Bundler::VersionConflict => e
            $stderr.puts("Plugin version conflict, aborting")
            raise(e)
          rescue ::Bundler::GemNotFound => e
            $stderr.puts("Plugin not found, aborting")
            raise(e)
          rescue => e
            if try >= options[:max_tries]
              $stderr.puts("Too many retries, aborting, caused by #{e.class}")
              $stderr.puts(e.message) if ENV["DEBUG"]
              raise(e)
            end

            try += 1
            $stderr.puts("Error #{e.class}, retrying #{try}/#{options[:max_tries]}")
            $stderr.puts(e.message) if ENV["DEBUG"]
            sleep(0.5)
          end
        end
      end
    end

    # build Bundler::CLI.start arguments array from the given options hash
    # @param option [Hash] the invoke_bundler! options hash
    # @return [Array<String>] Bundler::CLI.start string arguments array
    def self.bundler_arguments(options = {})
      arguments = []

      if options[:install]
        arguments << "install"
        arguments << "--clean" if options[:clean]
      elsif options[:update]
        arguments << "update"
        arguments << options[:update]
      elsif options[:clean]
        arguments << "clean"
      end

      arguments.flatten
    end
  end
end