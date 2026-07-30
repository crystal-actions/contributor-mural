module ContributorMural
  # Emits GitHub Actions workflow commands (annotations) and step outputs.
  # https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions
  module Annotations
    class_property io : IO = STDOUT

    def self.error(message : String, file : String? = nil, line : Int32? = nil) : Nil
      command("error", message, file, line)
    end

    def self.warning(message : String, file : String? = nil, line : Int32? = nil) : Nil
      command("warning", message, file, line)
    end

    def self.notice(message : String, file : String? = nil, line : Int32? = nil) : Nil
      command("notice", message, file, line)
    end

    # Appends a step output to GITHUB_OUTPUT. No-op outside of GitHub Actions.
    #
    # Reported rather than raised: the outputs are written after the mural
    # already is, so failing here would throw away work that is finished and
    # correct over a downstream step's convenience. The warning is what tells
    # anyone reading the log why `steps.*.outputs` came back empty.
    def self.output(key : String, value : String) : Nil
      return unless path = ENV["GITHUB_OUTPUT"]?
      File.open(path, "a", &.puts("#{key}=#{value}"))
    rescue ex : IO::Error
      warning("could not write the `#{key}` step output to #{path}: #{ex.message}")
    end

    private def self.command(kind : String, message : String, file : String?, line : Int32?) : Nil
      props = [] of String
      props << "file=#{escape_property(file)}" if file
      props << "line=#{line}" if line
      prop_str = props.empty? ? "" : " #{props.join(",")}"
      io.puts "::#{kind}#{prop_str}::#{escape_data(message)}"
    end

    private def self.escape_data(value : String) : String
      value.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    end

    private def self.escape_property(value : String) : String
      escape_data(value).gsub(":", "%3A").gsub(",", "%2C")
    end
  end
end
