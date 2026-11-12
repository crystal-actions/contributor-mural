module ContributorMural
  # Reads a file the config named by a repository-relative path. The config
  # validator rejects `..` and absolute paths lexically; what is left is what
  # only the filesystem can answer — a missing file, a symlink that leads out
  # of the repository, a file too large to take. Each caller words those in
  # its own vocabulary, so the reason comes back as a value.
  module WorkspaceFile
    enum Failure
      Missing
      Escapes
      TooLarge
      Unreadable
    end

    class Error < Exception
      getter failure : Failure

      def initialize(@failure : Failure, message : String? = nil)
        super(message)
      end
    end

    def self.read(workspace : String, path : String, limit : Int) : Bytes
      full = File.join(workspace, path)
      raise Error.new(Failure::Missing) unless File.file?(full)

      begin
        resolved = File.realpath(full)
        root = File.realpath(workspace)
      rescue ex : File::Error
        raise Error.new(Failure::Unreadable, ex.message)
      end
      raise Error.new(Failure::Escapes) unless inside?(root, resolved)

      size = File.size(resolved)
      raise Error.new(Failure::TooLarge, "#{size} bytes, limit #{limit}") if size > limit

      begin
        File.read(resolved).to_slice
      rescue ex : File::Error
        raise Error.new(Failure::Unreadable, ex.message)
      end
    end

    # Where writing `path` actually lands once symlinks are followed, relative
    # to the workspace — or nil when that is outside it, or inside `.git`. Judged
    # on the deepest part of it that already exists, so it can be asked before
    # any directory on the way is created — `mkdir_p` through a linked directory
    # would otherwise build the rest of the path outside.
    #
    # The landing spot is what has to be written *and* committed: staging the
    # link itself stages nothing, and the run reported "up to date" over a real
    # file it had just changed.
    def self.destination(workspace : String, path : String) : String?
      full = File.join(workspace, path)
      # A dangling link leads wherever it says, and nothing exists to resolve.
      return if File.symlink?(full) && !File.exists?(full)
      probe = full
      rest = [] of String
      until File.exists?(probe)
        rest.unshift(File.basename(probe))
        probe = File.dirname(probe)
      end
      root = File.realpath(workspace)
      target = File.join([File.realpath(probe)] + rest)
      return unless inside?(root, target) && target != root
      relative = target[root.size + 1..]
      # A link into git's own directory is inside the checkout and still the
      # one place a generated file must never go: it overwrote `.git/config`.
      return if relative.split(File::SEPARATOR).any? { |part| part.downcase == ".git" }
      relative
    end

    private def self.inside?(root : String, resolved : String) : Bool
      resolved == root || resolved.starts_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
