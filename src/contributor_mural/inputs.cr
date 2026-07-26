module ContributorMural
  # Action-facing settings. GitHub exposes each action input as an
  # `INPUT_<NAME>` env var; those take precedence over CLI flags.
  struct Inputs
    DEFAULT_CONFIG_PATH    = ".github/contributor-mural.yml"
    DEFAULT_COMMIT_MESSAGE = "chore: update contributor mural"

    getter config_path : String
    getter workspace : String
    getter token : String?
    getter commit_message : String
    getter? commit : Bool

    def initialize(@config_path, @workspace, @token, @commit_message, @commit)
    end

    def self.resolve(config_path : String? = nil, workspace : String? = nil,
                     commit_flag : Bool = false) : Inputs
      new(
        config_path: ENV["INPUT_CONFIG"]?.presence || config_path || DEFAULT_CONFIG_PATH,
        workspace: ENV["GITHUB_WORKSPACE"]?.presence || workspace || Dir.current,
        token: ENV["INPUT_TOKEN"]?.presence || ENV["GITHUB_TOKEN"]?.presence,
        commit_message: ENV["INPUT_COMMIT_MESSAGE"]?.presence || DEFAULT_COMMIT_MESSAGE,
        commit: resolve_commit(commit_flag),
      )
    end

    # Inside the action, commit by default unless the `no_commit` input is
    # set. On a local run, only commit when --commit was passed.
    private def self.resolve_commit(commit_flag : Bool) : Bool
      return false if env_bool("INPUT_NO_COMMIT")
      commit_flag || ENV["GITHUB_ACTIONS"]? == "true"
    end

    # Strict on purpose: `no_commit` exists to prevent a push, so a typo like
    # "tru" must not silently fall through to committing.
    private def self.env_bool(name : String) : Bool
      value = ENV[name]?.try(&.strip.downcase)
      return false if value.nil? || value.empty?
      case value
      when "true", "1", "yes" then true
      when "false", "0", "no" then false
      else
        raise ConfigError.new("#{name} must be true or false, got #{value.inspect}")
      end
    end
  end
end
