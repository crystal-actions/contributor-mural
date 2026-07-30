require "file_utils"
require "./spec_helper"

# Sets up a local bare "origin" plus a clone, so push is exercised without
# any network.
private def with_git_repo(&)
  root = File.tempname("mural_git")
  remote = File.join(root, "origin.git")
  clone = File.join(root, "work")
  Dir.mkdir_p(root)
  git("init", "--bare", "--initial-branch=main", remote)
  git("clone", remote, clone)
  git("-C", clone, "config", "user.name", "Spec Runner")
  git("-C", clone, "config", "user.email", "spec@example.com")
  File.write(File.join(clone, "README.md"), "seed")
  git("-C", clone, "add", "README.md")
  git("-C", clone, "commit", "-m", "seed")
  git("-C", clone, "push", "origin", "main")
  yield clone, remote
ensure
  FileUtils.rm_rf(root) if root
end

private def git(*args : String) : Nil
  output = IO::Memory.new
  status = Process.run("git", args.to_a, output: output, error: output)
  raise "git #{args.join(' ')} failed: #{output}" unless status.success?
end

private def git_output(*args : String) : String
  output = IO::Memory.new
  Process.run("git", args.to_a, output: output, error: output)
  output.to_s
end

describe ContributorMural::Committer do
  it "commits and pushes generated files" do
    with_git_repo do |clone, remote|
      Dir.mkdir_p(File.join(clone, "docs"))
      File.write(File.join(clone, "docs/wall.svg"), "<svg/>")

      committer = ContributorMural::Committer.new(clone, "chore: update contributor mural")
      committer.commit(["docs/wall.svg"]).should be_true

      log = git_output("-C", remote, "log", "--format=%s %an", "main")
      log.should contain("chore: update contributor mural github-actions[bot]")
      git_output("-C", remote, "ls-tree", "--name-only", "-r", "main")
        .should contain("docs/wall.svg")
    end
  end

  it "reports no change when the content is identical" do
    with_git_repo do |clone, _remote|
      File.write(File.join(clone, "wall.svg"), "<svg/>")
      committer = ContributorMural::Committer.new(clone, "msg")
      committer.commit(["wall.svg"]).should be_true
      committer.commit(["wall.svg"]).should be_false
    end
  end

  it "does not touch the repository's committer identity" do
    with_git_repo do |clone, _remote|
      File.write(File.join(clone, "wall.svg"), "<svg/>")
      ContributorMural::Committer.new(clone, "msg").commit(["wall.svg"])
      git_output("-C", clone, "config", "user.name").strip.should eq("Spec Runner")
    end
  end

  # Inside the runner the workspace is owned by a different uid than the
  # container user, so git will not touch it until it is marked safe. A docker
  # action's HOME is a directory the runner keeps, so `--add` on every run
  # appended another identical line to it, forever — invisible on a hosted
  # runner, unbounded on a self-hosted one.
  it "marks the workspace safe once, however many times it runs" do
    with_git_repo do |clone, _remote|
      home = File.tempname("mural_home")
      Dir.mkdir_p(home)
      previous_home = ENV["HOME"]?
      previous_actions = ENV["GITHUB_ACTIONS"]?
      begin
        ENV["HOME"] = home
        ENV["GITHUB_ACTIONS"] = "true"
        committer = ContributorMural::Committer.new(clone, "msg")
        3.times do |run|
          File.write(File.join(clone, "wall.svg"), "<svg id=\"#{run}\"/>")
          committer.commit(["wall.svg"])
        end

        entries = git_output("config", "--global", "--get-all", "safe.directory").lines.map(&.strip)
        entries.count(clone).should eq(1)
      ensure
        previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
        previous_actions ? (ENV["GITHUB_ACTIONS"] = previous_actions) : ENV.delete("GITHUB_ACTIONS")
        FileUtils.rm_rf(home)
      end
    end
  end

  it "raises a CommitError when the push is impossible" do
    with_git_repo do |clone, remote|
      FileUtils.rm_rf(remote)
      File.write(File.join(clone, "wall.svg"), "<svg/>")
      committer = ContributorMural::Committer.new(clone, "msg")
      expect_raises(ContributorMural::CommitError, /git push/) do
        committer.commit(["wall.svg"])
      end
    end
  end
end
