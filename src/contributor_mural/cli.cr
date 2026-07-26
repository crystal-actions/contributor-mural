require "option_parser"

module ContributorMural
  module CLI
    def self.run(argv = ARGV) : Int32
      config_flag = nil
      workspace_flag = nil
      commit_flag = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: contributor-mural [options]"
        opts.on("-c PATH", "--config PATH", "Config file (default: #{Inputs::DEFAULT_CONFIG_PATH})") { |value| config_flag = value }
        opts.on("-w DIR", "--workspace DIR", "Directory output paths are relative to (default: cwd)") { |value| workspace_flag = value }
        opts.on("--commit", "Commit and push the generated files") { commit_flag = true }
        opts.on("-v", "--version", "Print version") do
          puts VERSION
          exit 0
        end
        opts.on("-h", "--help", "Show help") do
          puts opts
          exit 0
        end
        opts.invalid_option do |flag|
          STDERR.puts "unknown option: #{flag}"
          STDERR.puts opts
          exit 2
        end
      end
      parser.parse(argv)

      begin
        inputs = Inputs.resolve(config_flag, workspace_flag, commit_flag)
      rescue ex : ConfigError
        Annotations.error(ex.message || "invalid action input")
        return 1
      end

      begin
        config = Config.load(inputs.config_path)
      rescue ex : ConfigError
        Annotations.error(ex.message || "invalid config", file: inputs.config_path, line: ex.line)
        return 1
      end

      github_source = config.api_sources? ? GitHubApi.new(inputs.token, config) : nil
      committer = inputs.commit? ? Committer.new(inputs.workspace, inputs.commit_message) : nil

      Runner.new(config, HTTPAvatarSource.new(inputs.workspace), inputs.workspace,
        github_source, committer, RsvgRasterizer.new).run
    end
  end
end
