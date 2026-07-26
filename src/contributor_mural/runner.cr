module ContributorMural
  # Orchestrates the pipeline: resolve users, embed avatars, render styles,
  # write files. Returns a process exit code.
  class Runner
    getter written_paths = [] of String

    def initialize(@config : Config, @avatar_source : AvatarSource,
                   @workspace : String = Dir.current,
                   @github_source : GitHubSource? = nil,
                   @committer : Committer? = nil,
                   @rasterizer : Rasterizer? = nil)
    end

    def run : Int32
      targets = @config.render_targets
      require_rasterizer! if targets.any? { |path, _style, _mode| png?(path) }

      users = Resolver.resolve(@config, fetch_api_users)
      if users.empty?
        # Writing an empty wall here would replace a good file with a blank
        # one and commit it, so refuse instead.
        raise ConfigError.new("no users to render — every source came back empty " \
                              "(check `users`, the source blocks, and `exclude`); existing files were left untouched")
      end

      embedder = Embedder.new(@avatar_source)
      user_count = 0
      warned = Set(String).new

      # Render everything before writing anything: a failure halfway through
      # would otherwise leave some outputs updated and others stale.
      rendered = targets.map do |path, style, mode_override|
        content = render_target(path, style, mode_override, users, embedder, warned)
        user_count = content[1]
        {path, content[0]}
      end

      rendered.each do |path, content|
        full_path = File.join(@workspace, path)
        Dir.mkdir_p(File.dirname(full_path))
        case content
        in Bytes  then File.write(full_path, content)
        in String then File.write(full_path, content)
        end
        written_paths << path
      end

      Annotations.output("paths", written_paths.join(","))
      Annotations.output("user_count", user_count.to_s)

      changed = false
      if committer = @committer
        changed = committer.commit(written_paths)
        Annotations.notice(changed ? "contributor mural updated" : "contributor mural already up to date")
      end
      Annotations.output("changed", changed.to_s)
      0
    rescue ex : ConfigError | AvatarError | ApiError | CommitError | RasterError
      Annotations.error(ex.message || ex.class.name)
      1
    end

    # Returns the file contents and how many users made it into them.
    private def render_target(path : String, style : Style, mode_override : ThemeMode?,
                              users : Array(ResolvedUser), embedder : Embedder,
                              warned : Set(String)) : {Bytes | String, Int32}
      mode = mode_override || @config.theme.mode
      # A PNG can't adapt to the viewer's theme, so pin auto to light.
      mode = ThemeMode::Light if png?(path) && mode.auto?

      renderer = Renderer.for(style, @config, mode)
      renderer.prepare(users)
      embedded, skipped = embedder.embed(users, renderer, @config.fail_on_missing?)
      skipped.each do |login|
        Annotations.warning("skipped #{login}: avatar could not be fetched") if warned.add?(login)
      end
      if embedded.empty?
        raise AvatarError.new("no avatars could be fetched — refusing to write an empty #{path}")
      end

      svg = renderer.render(Resolver.grouped(embedded, @config))
      content = png?(path) ? rasterize(svg).as(Bytes | String) : svg.as(Bytes | String)
      {content, embedded.size}
    end

    private def png?(path : String) : Bool
      path.ends_with?(".png")
    end

    # Checked up front so a missing rasterizer fails before any file is
    # touched, not midway through a multi-output run.
    private def require_rasterizer! : Nil
      return if @rasterizer
      raise RasterError.new("PNG output is configured but no rasterizer is available — " \
                            "install librsvg (`rsvg-convert`) or use .svg outputs")
    end

    private def rasterize(svg : String) : Bytes
      rasterizer = @rasterizer
      raise RasterError.new("PNG output configured but no rasterizer is available") unless rasterizer
      rasterizer.rasterize(svg, @config.png.scale)
    end

    private def fetch_api_users : Array(ResolvedUser)
      return [] of ResolvedUser unless @config.api_sources?

      source = @github_source
      unless source
        raise ConfigError.new("the configured sources need GitHub API access, but none is configured")
      end

      users = [] of ResolvedUser
      if block = @config.contributors
        users.concat source.contributors(default_repo("contributors", block.repo))
      end
      if block = @config.members
        users.concat source.members(block.org)
      end
      if block = @config.stargazers
        users.concat source.stargazers(default_repo("stargazers", block.repo))
      end
      if block = @config.sponsors
        login = block.login || ENV["GITHUB_REPOSITORY"]?.try(&.split('/').first?.presence)
        unless login
          raise ConfigError.new("sponsors `login` is not set and GITHUB_REPOSITORY is not available")
        end
        users.concat source.sponsors(login)
      end
      users
    end

    private def default_repo(section : String, configured : String?) : String
      configured || ENV["GITHUB_REPOSITORY"]? ||
        raise ConfigError.new("#{section} `repo` is not set and GITHUB_REPOSITORY is not available")
    end
  end
end
