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
      unless resolved == root || resolved.starts_with?("#{root}#{File::SEPARATOR}")
        raise Error.new(Failure::Escapes)
      end

      size = File.size(resolved)
      raise Error.new(Failure::TooLarge, "#{size} bytes, limit #{limit}") if size > limit

      begin
        File.read(resolved).to_slice
      rescue ex : File::Error
        raise Error.new(Failure::Unreadable, ex.message)
      end
    end
  end
end
