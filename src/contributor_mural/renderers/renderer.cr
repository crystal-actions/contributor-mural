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

    # Pixel size at which to fetch this user's avatar (2x render size for
    # crisp display on high-DPI screens).
    abstract def fetch_size(user : ResolvedUser) : Int32

    # Called with the full user list before avatars are fetched, so renderers
    # with relative sizing (mosaic tiers) can precompute per-user sizes.
    def prepare(users : Array(ResolvedUser)) : Nil
    end

    def render(groups : Array({String?, Array(EmbeddedUser)})) : String
      groups = groups.reject { |(_title, users)| users.empty? }
      if groups.empty?
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

      SVG.document(width, height) do |io|
        chrome(io)
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
      in .grid?      then Renderers::Grid.new(config, mode)
      in .honeycomb? then Renderers::Honeycomb.new(config, mode)
      in .mosaic?    then Renderers::Mosaic.new(config, mode)
      in .spiral?    then Renderers::Spiral.new(config, mode)
      in .orbit?     then Renderers::Orbit.new(config, mode)
      in .voronoi?   then Renderers::Voronoi.new(config, mode)
      in .stencil?   then Renderers::Stencil.new(config, mode)
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

    protected def label(io : String::Builder, text : String, x : Int32 | Float64, y : Int32 | Float64) : Nil
      io << %(    <text x="#{SVG.num(x)}" y="#{SVG.num(y)}" text-anchor="middle" font-family="#{SVG.escape(theme.font_family)}" font-size="11" #{label_paint}>#{SVG.escape(text)}</text>\n)
    end
  end
end
