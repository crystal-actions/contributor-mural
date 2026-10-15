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

    # Whether writing `path` stays inside the workspace once symlinks are
    # followed. Judged on the deepest part of it that already exists, so it can
    # be asked before any directory on the way is created — `mkdir_p` through a
    # linked directory would otherwise build the rest of the path outside.
    def self.writable?(workspace : String, path : String) : Bool
      full = File.join(workspace, path)
      # A dangling link leads wherever it says, and nothing exists to resolve.
      return false if File.symlink?(full) && !File.exists?(full)
      probe = full
      until File.exists?(probe)
        probe = File.dirname(probe)
      end
      inside?(File.realpath(workspace), File.realpath(probe))
    end

    private def self.inside?(root : String, resolved : String) : Bool
      resolved == root || resolved.starts_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
