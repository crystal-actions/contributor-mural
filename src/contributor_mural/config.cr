require "yaml"

module ContributorMural
  class ConfigError < Exception
    getter line : Int32?

    def initialize(message : String, @line : Int32? = nil)
      super(message)
    end
  end

  # Whether a name may stand as one segment of an API path.
  #
  # GitHub logins are letters, digits and hyphens; repository names add dots
  # and underscores. Anything outside that set either has no business in a name
  # or changes what the path means once it is pasted into one: `?` turns the
  # rest of the route into a query string, `#` truncates it, and `..` walks up
  # out of it — all of which reach a real endpoint and come back as a puzzling
  # error about GitHub rather than about the config that caused it.
  def self.path_segment?(value : String) : Bool
    value.matches?(/\A[A-Za-z0-9._-]+\z/) && value != "." && value != ".."
  end

  enum Style
    Grid
    Honeycomb
    Mosaic
    Spiral
    Orbit
    Voronoi
    Stencil
    Constellation
    Skyline
    Metro
  end

  enum Shape
    Circle
    Rounded
    Square
  end

  enum SortMode
    Weight
    Login
    None
  end

  class Config
    include YAML::Serializable
    include YAML::Serializable::Strict

    DEFAULT_OUTPUT = "CONTRIBUTOR_MURAL.svg"

    property style : Style = Style::Grid
    property output : String = DEFAULT_OUTPUT
    property outputs : Array(OutputEntry)? = nil
    property users : Array(UserEntry) = [] of UserEntry
    property groups : Array(String)? = nil
    # Every source block is enabled by being written down; nil means the key
    # was left out of the config entirely.
    property contributors : ContributorsConfig? = nil
    property members : MembersConfig? = nil
    property stargazers : StargazersConfig? = nil
    property sponsors : SponsorsConfig? = nil
    property exclude : Array(String) = [] of String
    property sort : SortMode = SortMode::Weight
    property limit : Int32? = nil
    property? fail_on_missing : Bool = false
    property grid : GridConfig = GridConfig.new
    property honeycomb : HoneycombConfig = HoneycombConfig.new
    property mosaic : MosaicConfig = MosaicConfig.new
    property spiral : SpiralConfig = SpiralConfig.new
    property orbit : OrbitConfig = OrbitConfig.new
    property voronoi : VoronoiConfig = VoronoiConfig.new
    property stencil : StencilConfig = StencilConfig.new
    property constellation : ConstellationConfig = ConstellationConfig.new
    property skyline : SkylineConfig = SkylineConfig.new
    property metro : MetroConfig = MetroConfig.new
    property theme : ThemeConfig = ThemeConfig.new
    property png : PngConfig = PngConfig.new

    def self.empty : Config
      parse("{}")
    end

    # True when any configured source needs the GitHub API.
    def api_sources? : Bool
      !contributors.nil? || !members.nil? || !stargazers.nil? || !sponsors.nil?
    end

    def self.load(path : String) : Config
      raise ConfigError.new("config file not found: #{path}") unless File.exists?(path)
      # `exists?` is not `readable?`: the path can be a directory, or a file the
      # container user cannot open. Both are ordinary mistakes — a `config`
      # input pointing at the wrong thing — and both reached the top of the
      # program as an unhandled exception, which in a workflow log means a
      # Crystal stack trace and no annotation at all.
      config =
        begin
          parse(File.read(path))
        rescue ex : IO::Error
          raise ConfigError.new("config file could not be read: #{path} (#{ex.message})")
        end
      config.validate!
      config
    end

    # Source blocks whose fields are all optional, so writing the key with
    # nothing under it is a complete configuration.
    private DEFAULTABLE_BLOCKS = %w[contributors stargazers sponsors]

    def self.parse(yaml : String) : Config
      reject_discarded_content(yaml)
      begin
        config = from_yaml(yaml)
      rescue ex : YAML::ParseException
        raise ConfigError.new("invalid config: #{friendly_parse_error(ex.message)}", ex.line_number)
      end
      config.enable_bare_blocks(yaml)
      config
    end

    # Config the parser reads past without complaining about, and which
    # therefore never reaches the mural.
    #
    # Both of these are legal YAML and both are silent — the run succeeds, and
    # whatever was written below the discarded point simply is not in the
    # picture. That is the worst way for a config mistake to behave, because
    # the only symptom is a wall missing people, which reads as a bug in the
    # sources rather than as something to go and fix in the file.
    private def self.reject_discarded_content(yaml : String) : Nil
      documents =
        begin
          YAML::Nodes.parse_all(yaml)
        rescue YAML::ParseException
          # Malformed input; `from_yaml` reports it with a line number.
          return
        end

      if second = documents[1]?
        raise ConfigError.new(
          "`---` starts a second YAML document and everything after it is ignored — " \
          "this file must be one document",
          second.start_line)
      end

      mapping = documents.first?.try(&.nodes.first?)
      return unless mapping.is_a?(YAML::Nodes::Mapping)
      seen = Set(String).new
      mapping.each do |key, _value|
        name = key.as?(YAML::Nodes::Scalar).try(&.value)
        next if name.nil? || seen.add?(name)
        raise ConfigError.new(
          "`#{name}` is set twice — YAML keeps only the last one, so everything " \
          "written under the first is ignored",
          key.start_line)
      end
    end

    # `contributors:` with nothing under it reads as YAML null, which would
    # otherwise look like "not configured". Writing the key is the whole
    # opt-in, so promote those to a default block.
    protected def enable_bare_blocks(yaml : String) : Nil
      document =
        begin
          YAML.parse(yaml)
        rescue YAML::ParseException
          return
        end
      mapping = document.as_h?
      return unless mapping

      mapping.each do |key, value|
        next unless value.raw.nil?
        case key.as_s?
        when "contributors" then self.contributors = ContributorsConfig.new
        when "stargazers"   then self.stargazers = StargazersConfig.new
        when "sponsors"     then self.sponsors = SponsorsConfig.new
        when "members"
          raise ConfigError.new("`members` needs an `org` — for example:\nmembers:\n  org: your-org")
        end
      end
    end

    # Crystal reports enum failures with its own type names
    # ("Unknown enum ContributorMural::Style value: \"gird\""). Rewrite those into
    # the field's vocabulary, listing what is actually accepted.
    private def self.friendly_parse_error(message : String?) : String
      return "could not be parsed" unless message

      # `source:` was replaced by writing the source blocks themselves.
      if message.matches?(/Unknown yaml attribute: source/i)
        return "`source` was removed — list the sources you want instead, " \
               "e.g. a `users:` list and/or a `contributors:` block"
      end

      match = message.match(/Unknown enum ContributorMural::(\w+) value: (".*?")/)
      return message unless match

      values =
        case match[1]
        when "Style"     then Style.names
        when "Shape"     then Shape.names
        when "SortMode"  then SortMode.names
        when "ThemeMode" then ThemeMode.names
        else                  [] of String
        end
      return message if values.empty?
      # Name the version: this list is authoritative only for the build that
      # printed it, and a stale image rejecting a style that does exist is
      # exactly the error that reads as "your config is wrong".
      "unknown value #{match[2]} (expected one of: #{values.map(&.downcase).join(", ")}) " \
      "— reported by contributor-mural v#{VERSION}"
    end

    # The (path, style, mode override) tuples to render: the `outputs` array
    # when present, otherwise the single `output`/`style` pair.
    def render_targets : Array({String, Style, ThemeMode?})
      if entries = outputs
        entries.map { |entry| {entry.path, entry.style || style, entry.mode} }
      else
        [{output, style, nil.as(ThemeMode?)}]
      end
    end

    def validate! : Nil
      errors = [] of String

      if users.empty? && !api_sources?
        errors << "nothing to render: add a `users` list, a `contributors:` block, " \
                  "or one of `members`/`stargazers`/`sponsors`"
      end

      validate_users(errors)
      validate_outputs(errors)
      validate_groups(errors)

      if lim = limit
        errors << "`limit` must be >= 1" if lim < 1
      end
      validate_api_sources(errors)

      errors.concat(grid.validate)
      errors.concat(honeycomb.validate)
      errors.concat(mosaic.validate)
      errors.concat(spiral.validate)
      errors.concat(orbit.validate)
      errors.concat(voronoi.validate)
      errors.concat(stencil.validate)
      errors.concat(constellation.validate)
      errors.concat(skyline.validate)
      errors.concat(metro.validate)
      errors.concat(theme.validate)

      raise ConfigError.new(errors.join("; ")) unless errors.empty?
    end

    private def validate_users(errors : Array(String)) : Nil
      seen = Set(String).new
      users.each do |user|
        errors << "user entry with empty `login`" if user.login.strip.empty?
        errors << "duplicate user login: #{user.login}" unless seen.add?(user.login.downcase)
        if weight = user.weight
          errors << "user #{user.login}: `weight` must be >= 1" if weight < 1
        end
        # Emphasis, not free rein: past 2x one avatar starts deciding the
        # layout for everyone else, and every style here has to keep the
        # people around it in the same picture.
        if scale = user.scale
          errors << "user #{user.login}: `scale` must be between 1 and 2" unless (1.0..2.0).includes?(scale)
        end
        validate_user_urls(errors, user)
      end
    end

    private def validate_user_urls(errors : Array(String), user : UserEntry) : Nil
      if (avatar = user.avatar_url) && !avatar.matches?(%r{\Ahttps?://}i)
        if avatar.starts_with?('/') || Path[avatar].parts.includes?("..")
          errors << "user #{user.login}: local `avatar_url` must be relative to the repository: #{avatar}"
        end
      end
      # The link lands in an <a href> inside a committed file; keep it to
      # schemes that cannot execute.
      if (link = user.link) && !link.matches?(%r{\A(https?://|mailto:|/|\#)}i)
        errors << "user #{user.login}: `link` must be http(s), mailto, or a repository-relative path: #{link}"
      end
    end

    private def validate_api_sources(errors : Array(String)) : Nil
      if block = contributors
        errors << "contributors `max` must be >= 1" if block.max < 1
        validate_repo(errors, "contributors", block.repo)
        validate_source_weight(errors, "contributors", block.weight)
      end
      if block = members
        if block.org.strip.empty?
          errors << "members `org` must not be empty"
        elsif !ContributorMural.path_segment?(block.org)
          errors << "members `org` must be a plain organization name: #{block.org.inspect}"
        end
        errors << "members `max` must be >= 1" if block.max < 1
        validate_source_weight(errors, "members", block.weight)
      end
      if block = stargazers
        errors << "stargazers `max` must be >= 1" if block.max < 1
        validate_repo(errors, "stargazers", block.repo)
        validate_source_weight(errors, "stargazers", block.weight)
      end
      if block = sponsors
        errors << "sponsors `max` must be >= 1" if block.max < 1
        validate_source_weight(errors, "sponsors", block.weight)
      end
    end

    # `repo` is optional — left out, it comes from GITHUB_REPOSITORY at run
    # time and the API client checks it there. Written down, it can be checked
    # here, where the error names the file and the line.
    private def validate_repo(errors : Array(String), section : String, repo : String?) : Nil
      return unless repo
      owner, slash, name = repo.partition('/')
      return if !slash.empty? && ContributorMural.path_segment?(owner) &&
                ContributorMural.path_segment?(name)
      errors << "#{section} `repo` must look like owner/name: #{repo.inspect}"
    end

    private def validate_source_weight(errors : Array(String), section : String, weight : Int32?) : Nil
      return unless weight
      errors << "#{section} `weight` must be >= 1" if weight < 1
    end

    private def validate_groups(errors : Array(String)) : Nil
      if explicit = groups
        errors << "`groups` entries must not be empty" if explicit.any?(&.strip.empty?)
        errors << "duplicate `groups` entries" if explicit.uniq.size != explicit.size

        known = explicit.to_set
        users.each do |user|
          if group = user.group
            errors << "user #{user.login}: group #{group.inspect} is not listed in `groups`" unless known.includes?(group)
          end
        end
        {
          "contributors" => contributors.try(&.group),
          "members"      => members.try(&.group),
          "stargazers"   => stargazers.try(&.group),
          "sponsors"     => sponsors.try(&.group),
        }.each do |section, group|
          next unless group
          errors << "#{section}: group #{group.inspect} is not listed in `groups`" unless known.includes?(group)
        end
      end
    end

    private def validate_outputs(errors : Array(String)) : Nil
      if (entries = outputs) && entries.empty?
        errors << "`outputs` must not be empty — remove it to use `output` instead"
      end
      if outputs && output != DEFAULT_OUTPUT
        errors << "`output` is ignored when `outputs` is set — keep only one of them"
      end

      paths = render_targets.map(&.first)
      paths.each { |path| validate_output_path(path, errors) }
      # Compared as the files they name rather than as the strings they were
      # written as: `./wall.svg` and `wall.svg` are one output, and the run
      # would otherwise render both, overwrite the first with the second, and
      # report two paths for the one file it left behind.
      written = paths.map { |path| Path[path].normalize.to_s }
      errors << "duplicate output paths" if written.uniq!.size != paths.size
      errors << "png `scale` must be positive" if png.scale <= 0
      errors << "png `scale` must be <= 8" if png.scale > 8
    end

    private def validate_output_path(path : String, errors : Array(String)) : Nil
      if path.strip.empty?
        errors << "output path must not be empty"
      elsif !path.ends_with?(".svg") && !path.ends_with?(".png")
        errors << "output path must end with .svg or .png: #{path}"
      end
      if path.starts_with?('/') || Path[path].parts.includes?("..")
        errors << "output path must be relative to the repository: #{path}"
      end
      if path.matches?(/[\x00-\x1f]/)
        errors << "output path must not contain control characters: #{path.inspect}"
      end
    end
  end

  class OutputEntry
    include YAML::Serializable
    include YAML::Serializable::Strict

    property path : String
    property style : Style? = nil
    # Per-output theme mode override, e.g. a light/dark PNG or SVG pair.
    property mode : ThemeMode? = nil
  end

  # Accepts `scale: 2` as well as `scale: 1.5`; YAML's Float64 converter
  # rejects bare integers, which reads as a bug to anyone writing a round
  # number.
  module NumberConverter
    def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Float64
      unless node.is_a?(YAML::Nodes::Scalar)
        node.raise "Expected a number"
      end
      node.value.to_f64? || node.raise("Expected a number, not #{node.value.inspect}")
    end

    def self.to_yaml(value : Float64, yaml : YAML::Nodes::Builder) : Nil
      value.to_yaml(yaml)
    end
  end

  class PngConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    @[YAML::Field(converter: ContributorMural::NumberConverter)]
    property scale : Float64 = 2.0

    def initialize
    end
  end

  class UserEntry
    include YAML::Serializable
    include YAML::Serializable::Strict

    property login : String
    property name : String? = nil
    property link : String? = nil
    property avatar_url : String? = nil
    property weight : Int32? = nil
    # Size multiplier for one person, applied after the ranking every style
    # does for itself. `weight` says where someone stands in the list, which
    # is not the same question as how large to draw them: a rank is relative
    # to everyone else and moves whenever the list does. Honoured by the
    # styles that derive a size per user (mosaic, spiral, orbit,
    # constellation, and skyline — the latter in height).
    @[YAML::Field(converter: ContributorMural::NumberConverter)]
    property scale : Float64? = nil
    property role : String? = nil
    property group : String? = nil
  end

  class ContributorsConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property repo : String? = nil
    property? include_bots : Bool = false
    property? include_anonymous : Bool = false
    property max : Int32 = 100
    property group : String? = nil
    # Flattens every user this source yields onto one rung, replacing the
    # contribution count. `users:` entries still win field by field, so the
    # curated list carries the exceptions and nothing else.
    property weight : Int32? = nil

    def initialize
    end
  end

  # Presence of the block enables the source.
  class MembersConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property org : String
    property max : Int32 = 100
    property group : String? = nil
    property weight : Int32? = nil
  end

  class StargazersConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property repo : String? = nil
    property max : Int32 = 100
    property group : String? = nil
    property weight : Int32? = nil

    def initialize
    end
  end

  class SponsorsConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property login : String? = nil
    property max : Int32 = 100
    property group : String? = nil
    # Set this to ignore tier amounts and treat every sponsor alike.
    property weight : Int32? = nil

    def initialize
    end
  end

  class GridConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property columns : Int32 = 8
    property avatar_size : Int32 = 64
    property shape : Shape = Shape::Circle
    property margin : Int32 = 8
    property? show_names : Bool = true
    property truncate : Int32 = 12

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "grid `columns` must be between 1 and 100" unless (1..100).includes?(columns)
      errors << "grid `avatar_size` must be between 8 and 512" unless (8..512).includes?(avatar_size)
      errors << "grid `margin` must be between 0 and 200" unless (0..200).includes?(margin)
      errors << "grid `truncate` must be >= 0" if truncate < 0
      errors
    end
  end

  class HoneycombConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property columns : Int32 = 9
    property cell_size : Int32 = 72
    property gap : Int32 = 4

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "honeycomb `columns` must be between 1 and 100" unless (1..100).includes?(columns)
      errors << "honeycomb `cell_size` must be between 8 and 512" unless (8..512).includes?(cell_size)
      errors << "honeycomb `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors
    end
  end

  class MosaicConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property width : Int32 = 800
    property base_cell : Int32 = 48
    property tiers : Array(Int32) = [3, 2, 1]
    property gap : Int32 = 2

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "mosaic `base_cell` must be between 8 and 512" unless (8..512).includes?(base_cell)
      errors << "mosaic `width` must be >= `base_cell`" if width < base_cell
      errors << "mosaic `width` must be <= 8000" if width > 8000
      errors << "mosaic `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      if tiers.empty?
        errors << "mosaic `tiers` must not be empty"
      elsif tiers.any? { |tier| tier < 1 || tier > 12 }
        errors << "mosaic `tiers` values must be between 1 and 12"
      end
      errors
    end
  end

  enum ThemeMode
    Auto
    Light
    Dark
  end

  record Palette,
    background : String,
    label_color : String,
    role_color : String,
    title_color : String

  class PaletteOverride
    include YAML::Serializable
    include YAML::Serializable::Strict

    property background : String? = nil
    property label_color : String? = nil
    property role_color : String? = nil
    property title_color : String? = nil

    def initialize
    end
  end

  class SpiralConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property max_size : Int32 = 72
    property min_size : Int32 = 32
    property gap : Int32 = 6
    property shape : Shape = Shape::Circle

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "spiral `max_size` must be between 8 and 512" unless (8..512).includes?(max_size)
      errors << "spiral `min_size` must be between 8 and 512" unless (8..512).includes?(min_size)
      errors << "spiral `min_size` must not exceed `max_size`" if min_size > max_size
      errors << "spiral `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors
    end
  end

  class OrbitConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property center_size : Int32 = 104
    property avatar_size : Int32 = 56
    property min_size : Int32 = 36
    property ring_gap : Int32 = 22
    property gap : Int32 = 8
    property? rings : Bool = true

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "orbit `center_size` must be between 8 and 512" unless (8..512).includes?(center_size)
      errors << "orbit `avatar_size` must be between 8 and 512" unless (8..512).includes?(avatar_size)
      errors << "orbit `min_size` must be between 8 and 512" unless (8..512).includes?(min_size)
      errors << "orbit `min_size` must not exceed `avatar_size`" if min_size > avatar_size
      errors << "orbit `ring_gap` must be between 1 and 400" unless (1..400).includes?(ring_gap)
      errors << "orbit `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors
    end
  end

  class VoronoiConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property width : Int32 = 720
    property cell_size : Int32 = 96
    property gap : Int32 = 4
    @[YAML::Field(converter: ContributorMural::NumberConverter)]
    property jitter : Float64 = 0.5
    @[YAML::Field(converter: ContributorMural::NumberConverter)]
    property weight_influence : Float64 = 0.6
    property? outline : Bool = false

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "voronoi `width` must be between 64 and 8000" unless (64..8000).includes?(width)
      errors << "voronoi `cell_size` must be between 16 and 512" unless (16..512).includes?(cell_size)
      errors << "voronoi `cell_size` must not exceed `width`" if cell_size > width
      errors << "voronoi `jitter` must be between 0 and 0.8" unless (0.0..0.8).includes?(jitter)
      errors << "voronoi `weight_influence` must be between 0 and 1" unless (0.0..1.0).includes?(weight_influence)
      errors << "voronoi `gap` must be between 0 and 64" unless (0..64).includes?(gap)
      # Every cell provably holds a disc of radius 0.25 * d_min around its
      # seed, and d_min is at least (1 - jitter) * pitch. The lead eats half
      # the gap off each side, so past this it could swallow a cell whole.
      if errors.empty? && gap > (limit = lead_limit)
        errors << "voronoi `gap` must be at most #{limit} for this `cell_size` and `jitter`"
      end
      errors
    end

    private def lead_limit : Int32
      (0.25 * (1.0 - jitter) * cell_size).floor.to_i
    end
  end

  class StencilConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    MAX_LINES      =  4
    MAX_LINE_CHARS = 16

    property text : String = "THANKS"
    property pixel_size : Int32 = 24
    property gap : Int32 = 4
    property letter_spacing : Int32 = 1
    property line_gap : Int32 = 1
    property shape : Shape = Shape::Circle
    property? ghosts : Bool = true

    def initialize
    end

    def glyph_lines : Array(Array(Char))
      StencilFont.lines(text)
    end

    def validate : Array(String)
      errors = [] of String
      lines = glyph_lines
      if lines.empty? || lines.all?(&.all?(' '))
        errors << "stencil `text` must contain at least one letter, digit, or symbol"
      end
      errors << "stencil `text` must be at most #{MAX_LINES} lines" if lines.size > MAX_LINES
      if lines.any? { |line| line.size > MAX_LINE_CHARS }
        errors << "stencil `text` must be at most #{MAX_LINE_CHARS} characters per line"
      end
      unknown = lines.flatten.reject { |char| StencilFont.supports?(char) }.uniq!
      unless unknown.empty?
        shown = unknown.first(3).map(&.to_s.inspect).join(", ")
        shown += ", …" if unknown.size > 3
        errors << "stencil `text` has unsupported characters: #{shown} (supported: #{StencilFont::ALPHABET})"
      end
      errors << "stencil `pixel_size` must be between 8 and 512" unless (8..512).includes?(pixel_size)
      errors << "stencil `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors << "stencil `letter_spacing` must be between 0 and 8" unless (0..8).includes?(letter_spacing)
      errors << "stencil `line_gap` must be between 0 and 8" unless (0..8).includes?(line_gap)
      errors
    end
  end

  class ConstellationConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property width : Int32 = 720
    property max_size : Int32 = 64
    property min_size : Int32 = 20
    property gap : Int32 = 12
    @[YAML::Field(converter: ContributorMural::NumberConverter)]
    property jitter : Float64 = 0.8
    property? lines : Bool = true
    property dust : Int32 = 4

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "constellation `width` must be between 64 and 8000" unless (64..8000).includes?(width)
      errors << "constellation `max_size` must be between 8 and 512" unless (8..512).includes?(max_size)
      errors << "constellation `min_size` must be between 8 and 512" unless (8..512).includes?(min_size)
      errors << "constellation `min_size` must not exceed `max_size`" if min_size > max_size
      errors << "constellation `width` must be >= `max_size` plus `gap`" if width < max_size + gap
      errors << "constellation `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors << "constellation `jitter` must be between 0 and 1" unless (0.0..1.0).includes?(jitter)
      errors << "constellation `dust` must be between 0 and 32" unless (0..32).includes?(dust)
      errors
    end
  end

  class SkylineConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    # Room a building needs above its avatar: the roof band plus the inset that
    # keeps the picture off the parapet.
    HEADROOM = 20

    property width : Int32 = 800
    property avatar_size : Int32 = 48
    property min_height : Int32 = 96
    property max_height : Int32 = 220
    property gap : Int32 = 6
    property shape : Shape = Shape::Rounded
    property? windows : Bool = true
    property? show_names : Bool = false
    property truncate : Int32 = 10

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "skyline `width` must be between 64 and 8000" unless (64..8000).includes?(width)
      errors << "skyline `avatar_size` must be between 8 and 512" unless (8..512).includes?(avatar_size)
      errors << "skyline `min_height` must be between 28 and 1024" unless (28..1024).includes?(min_height)
      errors << "skyline `max_height` must be between 28 and 1024" unless (28..1024).includes?(max_height)
      errors << "skyline `min_height` must not exceed `max_height`" if min_height > max_height
      # The shortest tower still has to hold its avatar under the roof band.
      if min_height < avatar_size + HEADROOM
        errors << "skyline `min_height` must be at least `avatar_size` plus #{HEADROOM}"
      end
      errors << "skyline `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      errors << "skyline `truncate` must be >= 0" if truncate < 0
      errors
    end
  end

  class MetroConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    property columns : Int32 = 6
    property station_size : Int32 = 56
    property line_width : Int32 = 8
    property gap : Int32 = 24
    # Split each section into one line per role, named after it — the people
    # who carry no role ride together on an unnamed line.
    property? role_lines : Bool = false
    # Interleave a section's lines so their routes cross one another, the way
    # a real network does. Only does anything where `role_lines` yields more
    # than one line.
    property? weave : Bool = false
    property? show_names : Bool = true
    property truncate : Int32 = 10

    def initialize
    end

    def validate : Array(String)
      errors = [] of String
      errors << "metro `columns` must be between 1 and 100" unless (1..100).includes?(columns)
      errors << "metro `station_size` must be between 8 and 512" unless (8..512).includes?(station_size)
      errors << "metro `line_width` must be between 2 and 64" unless (2..64).includes?(line_width)
      # A ring thicker than the avatar's radius swallows the face it frames.
      errors << "metro `line_width` must not exceed half of `station_size`" if line_width > station_size // 2
      errors << "metro `gap` must be between 0 and 200" unless (0..200).includes?(gap)
      # A woven rail passes midway between two station columns; the midpoint
      # clears the rings only when the gap funds it.
      if weave? && gap * 2 < line_width * 5
        errors << "metro `gap` must be at least 2.5 × `line_width` when `weave` is on"
      end
      errors << "metro `truncate` must be >= 0" if truncate < 0
      errors
    end
  end

  class ThemeConfig
    include YAML::Serializable
    include YAML::Serializable::Strict

    # {light, dark} palette pairs.
    PRESETS = {
      "github" => {
        Palette.new("transparent", "#57606a", "#6e7781", "#24292f"),
        Palette.new("transparent", "#8b949e", "#7d8590", "#e6edf3"),
      },
      "midnight" => {
        Palette.new("#0b1021", "#8f9bb3", "#5c6784", "#dfe6f3"),
        Palette.new("#0b1021", "#8f9bb3", "#5c6784", "#dfe6f3"),
      },
      "paper" => {
        Palette.new("#faf8f2", "#6f6857", "#a39a86", "#3d3629"),
        Palette.new("#221f1a", "#a89f8d", "#7d7666", "#ece5d8"),
      },
      "mono" => {
        Palette.new("#ffffff", "#444444", "#888888", "#000000"),
        Palette.new("#000000", "#bbbbbb", "#777777", "#ffffff"),
      },
    }

    # Colors land in a <style> block, so restrict them to a safe subset.
    SAFE_COLOR = /\A[#a-zA-Z0-9(),.%\- ]+\z/

    property preset : String = "github"
    property mode : ThemeMode = ThemeMode::Auto
    property background : String? = nil
    property label_color : String? = nil
    property role_color : String? = nil
    property title_color : String? = nil
    property dark : PaletteOverride = PaletteOverride.new
    property font_family : String = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"

    def initialize
    end

    def light_palette : Palette
      base = PRESETS[preset]?.try(&.first) || PRESETS["github"].first
      Palette.new(
        background: background || base.background,
        label_color: label_color || base.label_color,
        role_color: role_color || base.role_color,
        title_color: title_color || base.title_color,
      )
    end

    def dark_palette : Palette
      base = PRESETS[preset]?.try(&.last) || PRESETS["github"].last
      Palette.new(
        background: dark.background || base.background,
        label_color: dark.label_color || base.label_color,
        role_color: dark.role_color || base.role_color,
        title_color: dark.title_color || base.title_color,
      )
    end

    def validate : Array(String)
      errors = [] of String
      unless PRESETS.has_key?(preset)
        errors << "unknown theme `preset`: #{preset} (known: #{PRESETS.keys.join(", ")})"
      end
      {light_palette, dark_palette}.each do |palette|
        {palette.background, palette.label_color, palette.role_color, palette.title_color}.each do |color|
          errors << "theme color contains unsafe characters: #{color.inspect}" unless color.matches?(SAFE_COLOR)
        end
      end
      errors.uniq
    end
  end
end
