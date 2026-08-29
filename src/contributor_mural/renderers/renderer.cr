module ContributorMural
  # Turns embedded users into an SVG document. Styles implement `defs` (shared
  # clip paths, emitted once), `block_size`, and `draw_block` (one section of
  # users at a vertical offset); the base class stacks sections with optional
  # group titles and handles theming. In `auto` mode text and background get
  # CSS classes plus a prefers-color-scheme media query so the SVG follows the
  # viewer's theme (GitHub included); static modes inline the fills, which
  # keeps rasterizers happy. PNG output builds on the static path.
  abstract class Renderer
    TITLE_HEIGHT = 30.0
    SECTION_GAP  = 12.0

    def initialize(@config : Config, mode : ThemeMode? = nil)
      @mode = mode || @config.theme.mode
    end

    getter mode : ThemeMode

    # Document size of the most recent `render`, so a caller can report the
    # dimensions it just wrote without parsing the SVG back.
    getter last_size : {Float64, Float64} = {0.0, 0.0}

    # Pixel size at which to fetch this user's avatar (2x render size for
    # crisp display on high-DPI screens).
    abstract def fetch_size(user : ResolvedUser) : Int32

    # Called with the full user list before avatars are fetched, so renderers
    # with relative sizing (mosaic tiers) can precompute per-user sizes.
    def prepare(users : Array(ResolvedUser)) : Nil
    end

    # Per-document scratch a style has to clear before it draws another one:
    # section ordinals, colour cycles, generated clip-path ids, cached packs.
    # A hook rather than each style overriding `render` and remembering to call
    # `super` — a style that forgot inherited the last document's counters, and
    # the symptom is a second render coming out subtly different from the first.
    protected def reset_document : Nil
    end

    def render(groups : Array({String?, Array(EmbeddedUser)})) : String
      reset_document
      groups = groups.reject { |(_title, users)| users.empty? }
      @shared_faces = repeated_faces(groups)
      if groups.empty?
        @last_size = {16.0, 16.0}
        return SVG.document(16, 16) { |io| chrome(io) }
      end

      sized = groups.map { |(title, users)| {title, users, block_size(users)} }
      width = sized.max_of do |(title, _users, size)|
        # Section titles are left-aligned at title_inset and can run wider
        # than the avatar grid itself.
        title_width = title ? title_inset * 2 + text_width(title, 14.0) : 0.0
        Math.max(size[0], title_width)
      end
      height = 0.0
      sized.each_with_index do |(title, _users, size), index|
        height += SECTION_GAP if index.positive?
        height += TITLE_HEIGHT if title
        height += size[1]
      end

      @last_size = {width, height}
      SVG.document(width, height) do |io|
        chrome(io)
        face_defs(io)
        defs(io)
        y = 0.0
        sized.each_with_index do |(title, users, size), index|
          y += SECTION_GAP if index.positive?
          if title
            io << %(  <text x="#{SVG.num(title_inset)}" y="#{SVG.num(y + 19)}" text-anchor="start" font-family="#{SVG.escape(theme.font_family)}" font-size="14" font-weight="600" #{title_paint}>#{SVG.escape(title)}</text>\n)
            y += TITLE_HEIGHT
          end
          draw_block(io, users, y)
          y += size[1]
        end
      end
    end

    # Single-section convenience (specs, simple callers).
    def render(users : Array(EmbeddedUser)) : String
      render([{nil.as(String?), users}])
    end

    def self.for(style : Style, config : Config, mode : ThemeMode? = nil) : Renderer
      case style
      in .grid?          then Renderers::Grid.new(config, mode)
      in .honeycomb?     then Renderers::Honeycomb.new(config, mode)
      in .mosaic?        then Renderers::Mosaic.new(config, mode)
      in .spiral?        then Renderers::Spiral.new(config, mode)
      in .orbit?         then Renderers::Orbit.new(config, mode)
      in .voronoi?       then Renderers::Voronoi.new(config, mode)
      in .stencil?       then Renderers::Stencil.new(config, mode)
      in .constellation? then Renderers::Constellation.new(config, mode)
      in .skyline?       then Renderers::Skyline.new(config, mode)
      in .metro?         then Renderers::Metro.new(config, mode)
      in .pebble?        then Renderers::Pebble.new(config, mode)
      end
    end

    # Styles that can honour a per-user `scale`: the ones that already derive
    # a size per user, where an override is exact. The fixed lattices (grid,
    # honeycomb, stencil, metro) have nowhere to put an avatar larger than its
    # cell without overlapping a neighbour or leaving a hole, and voronoi sizes
    # cells by cutting the block up rather than by placing a shape — those
    # ignore `scale` rather than approximate it. Skyline honours it in the one
    # dimension it is free in: the emphasised tower grows taller, not wider.
    # Pebble sizes its disc before anything is placed and the pack pushes the
    # neighbours aside, so the multiplier lands exactly.
    def self.honors_scale?(style : Style) : Bool
      style.mosaic? || style.spiral? || style.orbit? ||
        style.constellation? || style.skyline? || style.pebble?
    end

    # Data URI => the id of the <symbol> holding it, for the faces this document
    # draws more than once. Empty on every wall where nobody is filed under two
    # sections, which is what keeps the markup for those byte-for-byte what it
    # has always been.
    @shared_faces = {} of String => String

    # A person in two sections is drawn twice, and an avatar's base64 is very
    # nearly the whole weight of an SVG — a second copy costs a face, a third
    # another one. So a repeated face is written once and referenced after that.
    #
    # Only repeats: a document where everyone appears once emits no <symbol> and
    # no <use>, so this cannot change what a single-section wall looks like.
    private def repeated_faces(groups : Array({String?, Array(EmbeddedUser)})) : Hash(String, String)
      drawn = Hash(String, Int32).new(0)
      groups.each { |(_title, users)| users.each { |user| drawn[user.data_uri] += 1 } }
      shared = {} of String => String
      drawn.each do |uri, count|
        shared[uri] = "mural-face-#{shared.size + 1}" if count > 1
      end
      shared
    end

    # `viewBox` plus `slice` is what lets one definition be drawn at whatever
    # size each section asks for: `<use>` cannot resize a bare <image>, but it
    # does establish the viewport a <symbol> scales itself into. The result is
    # the same crop-to-fill the inline <image> does.
    private def face_defs(io : String::Builder) : Nil
      @shared_faces.each do |uri, id|
        io << %(  <defs><symbol id="#{id}" viewBox="0 0 1 1" preserveAspectRatio="xMidYMid slice"><image href="#{uri}" width="1" height="1" preserveAspectRatio="xMidYMid slice"/></symbol></defs>\n)
      end
    end

    # Style-wide <defs>, emitted once per document.
    protected def defs(io : String::Builder) : Nil
    end

    # The avatar clip for a `shape`, emitted once per document. `square` needs
    # no clip at all, so callers keep gating the `clip-path` attribute on
    # `shape.square?` rather than on a return value from here.
    protected def shape_clip(io : String::Builder, id : String, shape : Shape) : Nil
      inner =
        case shape
        in .square?  then return
        in .circle?  then %(<circle cx="0.5" cy="0.5" r="0.5"/>)
        in .rounded? then %(<rect width="1" height="1" rx="0.15"/>)
        end
      io << %(  <defs><clipPath id="#{id}" clipPathUnits="objectBoundingBox">#{inner}</clipPath></defs>\n)
    end

    # Extra CSS a style needs in auto mode, emitted for both palettes.
    protected def style_rules(palette : Palette) : String
      ""
    end

    # Content size of one section: {width, height}.
    protected abstract def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}

    # Emit one section's content, shifted down by `y_offset`.
    protected abstract def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil

    # Left inset aligning section titles with block content.
    protected def title_inset : Float64
      8.0
    end

    # Deterministic noise in [0, 1), addressed by index rather than drawn from
    # a running generator: value k depends only on k and the salt, so layouts
    # survive being computed once for sizing and again for drawing. One copy
    # for every renderer, because the exact bits are golden-file contract.
    protected def noise(index : Int32, salt : UInt64) : Float64
      mix((index.to_u64 &+ salt &* 0x9e3779b97f4a7c15_u64) &* 6364136223846793005_u64 &+ 1442695040888963407_u64)
    end

    # The same noise keyed by a string — for per-person variation that has to
    # survive the list around it changing.
    protected def hash01(text : String, salt : UInt64) : Float64
      state = 0xcbf29ce484222325_u64
      text.each_byte { |byte| state = (state ^ byte) &* 0x100000001b3_u64 }
      mix(state &+ salt &* 0x9e3779b97f4a7c15_u64)
    end

    # The divisor is a power of two, so the result is exact in binary floating
    # point — which is what keeps the golden files stable.
    private def mix(state : UInt64) : Float64
      state = (state ^ (state >> 33)) &* 0xff51afd7ed558ccd_u64
      state ^= state >> 29
      ((state >> 43) & 0x1fffff).to_f64 / 0x200000.to_f64
    end

    protected def theme : ThemeConfig
      @config.theme
    end

    # The static palette for non-auto modes (auto's colors live in CSS).
    protected def palette : Palette
      mode.dark? ? theme.dark_palette : theme.light_palette
    end

    protected def label_paint : String
      mode.auto? ? %(class="mural-label") : %(fill="#{SVG.escape(palette.label_color)}")
    end

    protected def role_paint : String
      mode.auto? ? %(class="mural-role") : %(fill="#{SVG.escape(palette.role_color)}")
    end

    protected def title_paint : String
      mode.auto? ? %(class="mural-title") : %(fill="#{SVG.escape(palette.title_color)}")
    end

    # Theme style block (auto mode) and background rect.
    private def chrome(io : String::Builder) : Nil
      light = theme.light_palette
      dark = theme.dark_palette
      case mode
      in .auto?
        io << %(  <style>.mural-label{fill:#{light.label_color}}.mural-role{fill:#{light.role_color}}.mural-title{fill:#{light.title_color}}.mural-bg{fill:#{light.background}}#{style_rules(light)}@media (prefers-color-scheme:dark){.mural-label{fill:#{dark.label_color}}.mural-role{fill:#{dark.role_color}}.mural-title{fill:#{dark.title_color}}.mural-bg{fill:#{dark.background}}#{style_rules(dark)}}</style>\n)
        unless light.background == "transparent" && dark.background == "transparent"
          io << %(  <rect class="mural-bg" width="100%" height="100%"/>\n)
        end
      in .light?, .dark?
        background = palette.background
        unless background == "transparent"
          io << %(  <rect width="100%" height="100%" fill="#{SVG.escape(background)}"/>\n)
        end
      end
    end

    # `limit == 0` means no truncation; below 2 there is no room for an
    # ellipsis, so cut plainly rather than rendering a bare "…".
    protected def truncate(name : String, limit : Int32) : String
      return name if limit <= 0 || name.size <= limit
      return name[0, limit] if limit < 2
      "#{name[0, limit - 1]}…"
    end

    # Rough advance width for the label fonts (no font metrics available at
    # render time); used to widen the canvas so labels are not clipped.
    protected def text_width(text : String, font_size : Float64) : Float64
      # CJK and other wide scripts occupy roughly a full em.
      units = text.each_char.sum { |char| char.ord > 0x2E80 ? 1.0 : 0.55 }
      units * font_size
    end

    protected def title_for(user : EmbeddedUser) : String
      base = user.name == user.login ? user.login : "#{user.name} (@#{user.login})"
      if role = user.role
        "#{base} · #{role}"
      else
        base
      end
    end

    # Wraps everything one person contributes to the document in their link,
    # with the tooltip every style shows. Every avatar on every wall is
    # clickable and titled, so the two places a person's own text reaches the
    # markup — `link` and `title_for` — are escaped here rather than in each
    # style, where the next one added is the one that forgets.
    protected def linked(io : String::Builder, user : EmbeddedUser, & : -> Nil) : Nil
      io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
      io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
      yield
      io << "  </a>\n"
    end

    # The avatar itself. `clip` names a clipPath in the document's <defs>, or
    # is nil where the style draws the picture square — `square` needs no clip
    # at all, which is why `shape_clip` emits nothing for it.
    protected def avatar(io : String::Builder, user : EmbeddedUser,
                         x : Int32 | Float64, y : Int32 | Float64,
                         width : Int32 | Float64, height : Int32 | Float64,
                         clip : String? = nil) : Nil
      geometry = %(x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(width)}" height="#{SVG.num(height)}")
      if id = @shared_faces[user.data_uri]?
        # The clip goes on a wrapping <g> rather than on the <use> itself.
        # librsvg — the rasterizer, and so the PNG outputs — gives a <use> of a
        # <symbol> an empty bounding box, and a clipPath in objectBoundingBox
        # units then resolves to nothing at all: the avatar comes out blank.
        # A <g> has the bounding box of what it contains, and clips correctly
        # in both unit systems.
        reference = %(<use href="##{id}" #{geometry}/>)
        io << (clip ? %(    <g clip-path="url(##{clip})">#{reference}</g>\n) : "    #{reference}\n")
      else
        io << %(    <image href="#{user.data_uri}" #{geometry} preserveAspectRatio="xMidYMid slice")
        io << %( clip-path="url(##{clip})") if clip
        io << "/>\n"
      end
    end

    protected def label(io : String::Builder, text : String, x : Int32 | Float64, y : Int32 | Float64) : Nil
      io << %(    <text x="#{SVG.num(x)}" y="#{SVG.num(y)}" text-anchor="middle" font-family="#{SVG.escape(theme.font_family)}" font-size="11" #{label_paint}>#{SVG.escape(text)}</text>\n)
    end
  end
end
