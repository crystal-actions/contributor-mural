module ContributorMural
  # A generated file could not be written where the config asked for it.
  class OutputError < Exception
  end

  # Orchestrates the pipeline: resolve users, embed avatars, render styles,
  # write files. Returns a process exit code.
  class Runner
    # Each PNG is an `rsvg-convert` process, so this is bounded by cores rather
    # than by patience — unlike everything else in the pipeline, which waits on
    # the network.
    MAX_RASTER_JOBS = 4

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
      warn_unhonored_scale(targets)
      warn_inert_weave(targets)

      users = Resolver.resolve(@config, fetch_api_users)
      if users.empty?
        # Writing an empty wall here would replace a good file with a blank
        # one and commit it, so refuse instead.
        raise ConfigError.new("no users to render — every source came back empty " \
                              "(check `users`, the source blocks, and `exclude`); existing files were left untouched")
      end

      embedder = Embedder.new(@avatar_source)
      # Every renderer is built and asked what it needs *before* anything is
      # fetched, so all the targets' avatars come down in one fan-out. A config
      # with several outputs used to wait out a separate round of latency per
      # target, even where the targets wanted the same faces at the same size.
      plans = targets.map do |path, style, mode_override|
        renderer = Renderer.for(style, @config, target_mode(path, mode_override))
        renderer.prepare(users)
        {path, renderer}
      end
      embedder.warm(users, plans.map { |_path, renderer| renderer })

      user_count = 0
      warned = Set(String).new

      # Render everything before writing anything: a failure halfway through
      # would otherwise leave some outputs updated and others stale.
      drawn = plans.map do |path, renderer|
        svg, count = draw(path, renderer, users, embedder, warned)
        user_count = count
        {path, svg, renderer.last_size}
      end

      rendered = convert(drawn)
      rendered.each do |path, content, _dimensions|
        write(path, content)
        written_paths << path
      end

      paths = written_paths.join(",")
      Annotations.output("paths", paths)
      # `svg_path` is declared in action.yml and documented as the deprecated
      # alias kept for workflows written before `outputs` existed. It was never
      # actually emitted, so those workflows have been reading the empty string
      # — the one failure an alias exists to prevent.
      Annotations.output("svg_path", paths)
      Annotations.output("user_count", user_count.to_s)
      # Reported for the first target only — it is what a single-output config
      # (the common case) means by "the mural", and the only entry of `paths`
      # a caller can write into an <img> without parsing the list.
      if first = rendered.first?
        Annotations.output("width", first[2][0].to_s)
        Annotations.output("height", first[2][1].to_s)
      end

      changed = false
      if committer = @committer
        changed = committer.commit(written_paths)
        Annotations.notice(changed ? "contributor mural updated" : "contributor mural already up to date")
      end
      Annotations.output("changed", changed.to_s)
      0
    rescue ex : ConfigError | AvatarError | ApiError | CommitError | RasterError | OutputError
      Annotations.error(ex.message || ex.class.name)
      1
    end

    # An output path is checked for shape at config load, but nothing there can
    # know what is already on disk: a directory sitting where a file goes, a
    # file sitting where a directory goes, a read-only mount. Each of those
    # reached the top of the program as an unhandled exception, which in a
    # workflow log means a Crystal stack trace and no annotation at all.
    private def write(path : String, content : Bytes | String) : Nil
      full_path = File.join(@workspace, path)
      Dir.mkdir_p(File.dirname(full_path))
      case content
      in Bytes  then File.write(full_path, content)
      in String then File.write(full_path, content)
      end
    rescue ex : IO::Error
      raise OutputError.new("could not write #{path}: #{ex.message}")
    end

    private def target_mode(path : String, mode_override : ThemeMode?) : ThemeMode
      mode = mode_override || @config.theme.mode
      # A PNG can't adapt to the viewer's theme, so pin auto to light.
      png?(path) && mode.auto? ? ThemeMode::Light : mode
    end

    # Returns the SVG for one target and how many users made it into it.
    private def draw(path : String, renderer : Renderer, users : Array(ResolvedUser),
                     embedder : Embedder, warned : Set(String)) : {String, Int32}
      embedded, skipped = embedder.embed(users, renderer, @config.fail_on_missing?)
      skipped.each do |skip|
        Annotations.warning("skipped #{skip.login}: #{skip.reason}") if warned.add?(skip.login)
      end
      if embedded.empty?
        raise AvatarError.new("no avatars could be fetched — refusing to write an empty #{path}")
      end

      {renderer.render(Resolver.grouped(embedded, @config)), embedded.size}
    end

    # Turns drawn SVGs into what actually gets written, with the pixel size of
    # each. Every PNG is an independent subprocess, so they convert side by side
    # rather than one after another — the SVG targets pass straight through.
    private def convert(drawn : Array({String, String, {Float64, Float64}})) : Array({String, Bytes | String, {Int32, Int32}})
      Concurrent.map(drawn, MAX_RASTER_JOBS) do |target|
        path, svg, svg_size = target
        if png?(path)
          png = rasterize(svg)
          # Read the size back off the PNG rather than scaling the SVG's own:
          # rsvg-convert decides the rounding, and a reported size that is one
          # pixel off is worse than none for anyone writing it into an <img>.
          {path, png.as(Bytes | String), png_size(png) || scaled_size(svg_size)}
        else
          {path, svg.as(Bytes | String), {svg_size[0].ceil.to_i, svg_size[1].ceil.to_i}}
        end
      end
    end

    # Width and height out of the IHDR chunk, which a PNG is required to open
    # with: 8-byte signature, 4-byte length, "IHDR", then the two dimensions
    # as big-endian 32-bit integers.
    private def png_size(png : Bytes) : {Int32, Int32}?
      return if png.size < 24
      return unless png[12, 4] == "IHDR".to_slice
      width = IO::ByteFormat::BigEndian.decode(UInt32, png[16, 4])
      height = IO::ByteFormat::BigEndian.decode(UInt32, png[20, 4])
      return if width.zero? || height.zero?
      {width.to_i, height.to_i}
    end

    private def scaled_size(size : {Float64, Float64}) : {Int32, Int32}
      {(size[0] * @config.png.scale).ceil.to_i, (size[1] * @config.png.scale).ceil.to_i}
    end

    private def png?(path : String) : Bool
      path.ends_with?(".png")
    end

    # A `scale` the style cannot express is a silent no-op, which reads as
    # "the option does not work" rather than "this style has no room for it".
    # Name the styles that dropped it, once, before anything is written.
    private def warn_unhonored_scale(targets : Array({String, Style, ThemeMode?})) : Nil
      return unless @config.users.any?(&.scale)

      ignored = targets.map { |_path, style, _mode| style }.uniq!
        .reject! { |style| Renderer.honors_scale?(style) }
      return if ignored.empty?

      Annotations.warning("per-user `scale` is ignored by #{ignored.map(&.to_s.downcase).join(", ")} — " \
                          "mosaic, spiral, orbit, constellation, skyline, and pebble are the styles that honour it")
    end

    # `weave` interleaves a section's lines, so without `role_lines` there is
    # only ever one line to interleave and the option draws exactly what it
    # would have drawn anyway. The validator still holds it to the `gap` rule,
    # which makes the silence read as "it is on and working".
    private def warn_inert_weave(targets : Array({String, Style, ThemeMode?})) : Nil
      return unless @config.metro.weave?
      return if @config.metro.role_lines?
      return unless targets.any? { |_path, style, _mode| style.metro? }

      Annotations.warning("metro `weave` needs `role_lines` — it interleaves the lines a section " \
                          "is split into, and without roles a section is a single line")
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

      source = @github_source ||
               raise ConfigError.new("the configured sources need GitHub API access, but none is configured")

      # Everything that can be settled without the network is settled here, on
      # this fiber, in configuration order: a missing `repo` has to read the same
      # way it always did rather than depending on which request failed first.
      # (Each source also needs its own local to close over — two sources
      # sharing one `repo` variable would both end up fetching the second one.)
      fetches = [] of Proc(Array(ResolvedUser))
      if block = @config.contributors
        contributors_repo = default_repo("contributors", block.repo)
        fetches << -> { source.contributors(contributors_repo) }
      end
      if block = @config.members
        org = block.org
        fetches << -> { source.members(org) }
      end
      if block = @config.stargazers
        stargazers_repo = default_repo("stargazers", block.repo)
        fetches << -> { source.stargazers(stargazers_repo) }
      end
      if block = @config.sponsors
        sponsors_login = block.login ||
                         ENV["GITHUB_REPOSITORY"]?.try(&.split('/').first?.presence) ||
                         raise ConfigError.new("sponsors `login` is not set and GITHUB_REPOSITORY is not available")
        fetches << -> { source.sponsors(sponsors_login) }
      end

      # The sources are independent round trips to the same host, so running
      # them together turns four waits into one. Results come back in
      # configuration order, and so does the first error, which leaves nothing
      # downstream able to tell the difference except in how long it took.
      per_source = Concurrent.map(fetches, fetches.size, &.call)
      per_source.flatten
    end

    private def default_repo(section : String, configured : String?) : String
      configured || ENV["GITHUB_REPOSITORY"]? ||
        raise ConfigError.new("#{section} `repo` is not set and GITHUB_REPOSITORY is not available")
    end
  end
end
