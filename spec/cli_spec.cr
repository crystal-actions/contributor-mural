require "file_utils"
require "./spec_helper"

# `CLI.run` is what the container image actually invokes, and it is the only
# place the exit code is decided. Everything under it has its own spec; what is
# untested without this file is the wiring — that a bad input is reported as an
# annotation and exits 1 rather than reaching the top of the program as a
# Crystal stack trace, and that a good config exits 0 with the file on disk.
#
# The runs here stay offline: every user carries a workspace-relative
# `avatar_url`, which `HTTPAvatarSource` reads from the filesystem instead of
# fetching, and no source block is configured, so no API client is built.

private ENV_VARS = %w[INPUT_CONFIG INPUT_TOKEN INPUT_NO_COMMIT INPUT_COMMIT_MESSAGE
  GITHUB_WORKSPACE GITHUB_TOKEN GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_REPOSITORY]

# One-pixel-ish PNG. Nothing reads the bytes — the local reader keys off the
# extension and the embedder base64s whatever it is handed.
private AVATAR = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]

private record CLIRun, code : Int32, log : String, workspace : String

# Runs the CLI against a throwaway workspace holding `config` (written as
# `mural.yml`) and a local avatar, with the action's env vars cleared so a
# developer's own shell cannot change the outcome.
private def run_cli(config : String?, args : Array(String)? = nil,
                    env : Hash(String, String) = {} of String => String, &) : Nil
  workspace = File.tempname("mural_cli")
  Dir.mkdir_p(workspace)
  File.write(File.join(workspace, "avatar.png"), AVATAR)
  config_path = File.join(workspace, "mural.yml")
  File.write(config_path, config) if config

  saved = ENV_VARS.to_h { |name| {name, ENV[name]?} }
  ENV_VARS.each { |name| ENV.delete(name) }
  env.each { |name, value| ENV[name] = value }

  log = IO::Memory.new
  ContributorMural::Annotations.io = log
  begin
    code = ContributorMural::CLI.run(args || ["-c", config_path, "-w", workspace])
    yield CLIRun.new(code, log.to_s, workspace)
  ensure
    ContributorMural::Annotations.io = STDOUT
    saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
    FileUtils.rm_rf(workspace)
  end
end

private VALID_CONFIG = <<-YAML
  style: grid
  output: wall.svg
  users:
    - login: alpha
      avatar_url: avatar.png
    - login: bravo
      avatar_url: avatar.png
  YAML

describe ContributorMural::CLI do
  it "renders the config and exits 0" do
    run_cli(VALID_CONFIG) do |result|
      result.code.should eq(0), result.log
      svg = File.read(File.join(result.workspace, "wall.svg"))
      svg.should start_with("<svg")
      svg.should contain("alpha")
      svg.should contain("bravo")
    end
  end

  # First line of every run: an image tag can move under a pinned action ref,
  # so "which build is this" has to be answerable from the log alone.
  it "prints the version before doing anything" do
    run_cli(VALID_CONFIG) do |result|
      result.log.lines.first.should eq("contributor-mural v#{ContributorMural::VERSION}")
    end
  end

  it "resolves output paths against --workspace, not the working directory" do
    run_cli("users:\n  - login: alpha\n    avatar_url: avatar.png\noutput: docs/wall.svg") do |result|
      result.code.should eq(0), result.log
      File.exists?(File.join(result.workspace, "docs", "wall.svg")).should be_true
    end
  end

  it "writes every entry of a multi-output config" do
    config = <<-YAML
      users:
        - login: alpha
          avatar_url: avatar.png
      outputs:
        - path: light.svg
          mode: light
        - path: dark.svg
          mode: dark
      YAML

    run_cli(config) do |result|
      result.code.should eq(0), result.log
      File.exists?(File.join(result.workspace, "light.svg")).should be_true
      File.exists?(File.join(result.workspace, "dark.svg")).should be_true
    end
  end

  it "reports a missing config file as an annotation and exits 1" do
    run_cli(nil) do |result|
      result.code.should eq(1)
      result.log.should contain("::error")
      result.log.should contain("config file not found")
    end
  end

  # A parse error knows its line, and the annotation is what puts the marker on
  # the right row of the file in the PR view.
  it "points the annotation at the file and line of a syntax error" do
    run_cli("users:\n  - login: alpha\n   bad: [") do |result|
      result.code.should eq(1)
      result.log.should contain("::error file=")
      result.log.should contain("line=")
    end
  end

  it "reports a config that fails validation and exits 1" do
    run_cli("users: []") do |result|
      result.code.should eq(1)
      result.log.should contain("::error")
      result.log.should contain("nothing to render")
    end
  end

  # `no_commit` exists to prevent a push, so a typo must not fall through to
  # committing — it has to stop the run before anything is rendered.
  it "reports an unreadable action input and exits 1" do
    run_cli(VALID_CONFIG, env: {"INPUT_NO_COMMIT" => "tru"}) do |result|
      result.code.should eq(1)
      result.log.should contain("INPUT_NO_COMMIT must be true or false")
      File.exists?(File.join(result.workspace, "wall.svg")).should be_false
    end
  end

  it "lets INPUT_CONFIG override the --config flag the way the action does" do
    run_cli(VALID_CONFIG) do |result|
      # Re-run inside the same workspace with the env var pointing elsewhere.
      other = File.join(result.workspace, "other.yml")
      File.write(other, "users:\n  - login: charlie\n    avatar_url: avatar.png\noutput: other.svg")
      ENV["INPUT_CONFIG"] = other
      begin
        ContributorMural::CLI.run(["-c", File.join(result.workspace, "mural.yml"), "-w", result.workspace])
          .should eq(0)
        File.exists?(File.join(result.workspace, "other.svg")).should be_true
      ensure
        ENV.delete("INPUT_CONFIG")
      end
    end
  end

  it "does not commit without --commit" do
    run_cli(VALID_CONFIG) do |result|
      result.code.should eq(0), result.log
      # The committer is only built when the resolved inputs ask for it; a run
      # that built one here would have shelled out to git in a directory that
      # is not a repository and failed.
      result.log.should_not contain("contributor mural updated")
      result.log.should_not contain("contributor mural already up to date")
    end
  end
end
