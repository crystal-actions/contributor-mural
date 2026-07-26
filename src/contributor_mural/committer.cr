module ContributorMural
  class CommitError < Exception
  end

  # Commits and pushes generated files with git. Identity is passed per
  # command (-c) so the user's git config is never mutated; the global
  # safe.directory entry is only added inside the actions runner, where the
  # workspace is owned by a different uid than the container user.
  class Committer
    BOT_NAME  = "github-actions[bot]"
    BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"

    def initialize(@workspace : String, @message : String)
    end

    # Returns true when a commit was pushed, false when nothing changed.
    def commit(paths : Array(String)) : Bool
      if ENV["GITHUB_ACTIONS"]? == "true"
        run(["config", "--global", "--add", "safe.directory", @workspace], repo: false)
      end
      run(["add", "--"] + paths)
      return false unless staged_changes?(paths)

      run(["-c", "user.name=#{BOT_NAME}", "-c", "user.email=#{BOT_EMAIL}",
           "commit", "-m", @message, "--"] + paths)
      begin
        run(["push"])
      rescue ex : CommitError
        # The commit already exists locally; on a reused workspace the next
        # run would see a clean index and wrongly report "up to date".
        run(["reset", "--soft", "HEAD~1"]) rescue nil
        raise CommitError.new("#{ex.message}\n" \
                              "The generated files were not pushed. Common causes: the workflow needs " \
                              "`permissions: contents: write`; the branch moved (add a `concurrency` group); " \
                              "or the event has no pushable branch (pull_request runs a detached HEAD — " \
                              "use `no_commit: true` there).")
      end
      true
    end

    # Scoped to our own paths so unrelated staged work from an earlier step
    # is neither counted as our change nor swept into our commit.
    private def staged_changes?(paths : Array(String)) : Bool
      status = Process.run("git", ["-C", @workspace, "diff", "--cached", "--quiet", "--"] + paths)
      !status.success?
    end

    private def run(command : Array(String), repo : Bool = true) : Nil
      argv = repo ? ["-C", @workspace] : [] of String
      argv += command
      output = IO::Memory.new
      status = Process.run("git", argv, output: output, error: output)
      return if status.success?
      raise CommitError.new("`git #{command.join(' ')}` failed: #{output.to_s.strip}")
    rescue File::NotFoundError
      raise CommitError.new("git is required to commit the generated files but was not found on PATH")
    end
  end
end
