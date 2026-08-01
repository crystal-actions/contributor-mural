module ContributorMural::Renderers
  # A city skyline: each contributor is a building on a shared street, its
  # height set by their weight — the people carrying the project are the
  # towers — with the avatar up top like a rooftop billboard and a hash-lit
  # grid of windows below it. Buildings wrap into further rows past the
  # configured width, each row bottom-aligned on its own ground strip.
  class Skyline < Renderer
    CLIP_ID = "skyline-clip"

    # Side padding between a building's wall and its avatar; a building is
    # `avatar_size + 2 * PAD` wide.
    PAD = 6.0
    # The roof zone every silhouette variation stays inside, so the avatar
    # always sits against the full-width body underneath it.
    ROOF_BAND =  8.0
    ANTENNA_W =  2.0
    ANTENNA_H = 12.0
    GROUND_H  =  2.0
    # Headroom over each row's tallest extent.
    TOP_PAD =  4.0
    ROW_GAP = 24.0
    LABEL_H = 16.0
    # Share of windows lit.
    LIT_RATIO = 0.5
    # Most rows of windows one wall will draw. Well clear of what the default
    # band asks for (a 220px tower glazes 12), so it only ever bites the
    # towers that would otherwise be drawn in specks.
    FLOOR_CAP = 32
    # Height jitter as a share of the smallest step between weight ranks —
    # under half, so jitter can never reorder what the weights decided.
    JITTER_SHARE = 0.35

    SALT_HEIGHT = 1_u64

    # How many roof silhouettes `draw_roof` knows.
    ROOF_TYPES = 6

    # A clean daytime silhouette on light walls, a dusk city on dark ones.
    # Hardcoded per mode like orbit's ring: the four-colour palette record has
    # no slot for architecture, and a per-style palette is not worth its keys.
    LIGHT_INKS = {building: "#d0d7de", lit: "#fff8c5", unlit: "#afb8c1", ground: "#afb8c1"}
    DARK_INKS  = {building: "#21262d", lit: "#f2cc60", unlit: "#30363d", ground: "#30363d"}

    # Anyone whose label reaches the document, whether or not their avatar has
    # been fetched yet.
    private alias Labelled = ResolvedUser | EmbeddedUser

    @heights = {} of String => Float64
    @antenna = Set(String).new
    @gutter = 0.0
    @section = 0

    # Heights rank the *distinct* weights across the whole document — a
    # thousandfold outlier lands at the top of the band exactly like a
    # twofold one, and a section of equals renders low rather than faking a
    # skyline of towers. Keyed by login, so sectioning cannot move anyone.
    def prepare(users : Array(ResolvedUser)) : Nil
      skyline = @config.skyline
      range = (skyline.max_height - skyline.min_height).to_f
      distinct = users.map(&.weight).uniq!.sort!

      if distinct.size <= 1
        # Everyone on one rung: spread over the whole band by hash, or the
        # wall is a single flat roofline.
        users.each do |user|
          @heights[user.login] = (skyline.min_height + range * hash01(user.login, SALT_HEIGHT)) * user.scale
        end
      else
        span = (distinct.size - 1).to_f
        base = {} of Int32 => Float64
        distinct.each_with_index do |weight, index|
          # The spiral's power taper, measured down from the top: the leaders
          # drop fast and the long tail flattens into an even skyline.
          base[weight] = skyline.max_height - range * ((span - index) / span) ** 0.45
        end
        # Jitter breaks up the plateau a shared weight makes. Bounded by a
        # third of the smallest step between ranks, so the jittered bands
        # stay disjoint and the roofline keeps the order the weights set.
        min_gap = Float64::MAX
        distinct.each_cons(2, reuse: true) do |pair|
          step = base[pair[1]] - base[pair[0]]
          min_gap = step if step < min_gap
        end
        amp = JITTER_SHARE * min_gap
        top = distinct.last
        users.each do |user|
          height = base[user.weight]
          # The top rank is the anchor: pinned to `max_height` exactly.
          height += amp * (2 * hash01(user.login, SALT_HEIGHT) - 1) unless user.weight == top
          height = height.clamp(skyline.min_height.to_f, skyline.max_height.to_f)
          # `scale` grows the tower, not the avatar: horizontally this is a
          # fixed lattice, but the sky is free.
          @heights[user.login] = height * user.scale
        end
      end

      # One mast per section's skyline: its tallest tower, first on ties.
      users.group_by(&.group).each_value do |members|
        mast = members.first
        members.each do |member|
          mast = member if height_for(member.login) > height_for(mast.login)
        end
        @antenna << mast.login
      end
      @gutter = overhang(users)
    end

    def fetch_size(user : ResolvedUser) : Int32
      @config.skyline.avatar_size * 2
    end

    # Building cosmetics are salted per section, so a renderer reused for a
    # second document has to start counting over.
    def render(groups : Array({String?, Array(EmbeddedUser)})) : String
      @section = 0
      super
    end

    protected def title_inset : Float64
      @config.skyline.gap + @gutter
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, @config.skyline.shape)
    end

    protected def style_rules(palette : Palette) : String
      inks = palette == theme.dark_palette ? DARK_INKS : LIGHT_INKS
      rules = ".mural-building{fill:#{inks[:building]}}.mural-ground{fill:#{inks[:ground]}}"
      if @config.skyline.windows?
        rules += ".mural-window-lit{fill:#{inks[:lit]}}.mural-window-dark{fill:#{inks[:unlit]}}"
      end
      rules
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      return {16.0, 16.0} if users.empty?
      _rows, width, height = layout(users)
      {width, height}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      return if users.empty?

      skyline = @config.skyline
      rows, width, _height = layout(users)
      wall = skyline.avatar_size + 2 * PAD
      left = skyline.gap + gutter_for(users)
      clipped = !skyline.shape.square?

      y = y_offset
      building = 0
      rows.each_with_index do |row, index|
        y += ROW_GAP if index.positive?
        baseline = y + TOP_PAD + extent(row)
        io << %(  <rect x="0" y="#{SVG.num(baseline)}" width="#{SVG.num(width)}" height="#{SVG.num(GROUND_H)}" #{ground_paint}/>\n)
        row.each_with_index do |user, column|
          draw_building(io, user, building, left + column * (wall + skyline.gap), wall, baseline, clipped)
          building += 1
        end
        y = baseline + GROUND_H
        y += LABEL_H if skyline.show_names?
      end

      @section += 1
    end

    # {rows, block width, block height}; pure, so sizing and drawing agree.
    private def layout(users : Array(EmbeddedUser)) : {Array(Array(EmbeddedUser)), Float64, Float64}
      skyline = @config.skyline
      rows = users.each_slice(columns).to_a
      used = Math.min(columns, users.size)
      inset = skyline.gap + gutter_for(users)
      width = 2 * inset + used * (skyline.avatar_size + 2 * PAD) + (used - 1) * skyline.gap

      height = 0.0
      rows.each_with_index do |row, index|
        height += ROW_GAP if index.positive?
        height += TOP_PAD + extent(row) + GROUND_H
        height += LABEL_H if skyline.show_names?
      end
      {rows, width, height}
    end

    private def columns : Int32
      skyline = @config.skyline
      pitch = skyline.avatar_size + (2 * PAD).to_i + skyline.gap
      Math.max((skyline.width + skyline.gap) // pitch, 1)
    end

    # A row is as tall as its tallest building, mast included.
    private def extent(row : Array(EmbeddedUser)) : Float64
      row.max_of do |user|
        height_for(user.login) + (@antenna.includes?(user.login) ? ANTENNA_H : 0.0)
      end
    end

    private def draw_building(io : String::Builder, user : EmbeddedUser, index : Int32, x : Float64,
                              wall : Float64, baseline : Float64, clipped : Bool) : Nil
      skyline = @config.skyline
      height = height_for(user.login)
      top = baseline - height
      salt = @section.to_u64 &* 104729_u64 &+ 3

      # A per-building wall inset (0–2px a side) breaks the block out of one
      # uniform width without leaving the lattice: the inset always stays
      # under PAD, so the avatar and the windows keep their footing.
      inset = (noise(index * 3, salt) * 3).to_i.to_f
      body_x = x + inset
      body_w = wall - 2 * inset

      io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
      io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
      io << %(    <g #{building_paint}>\n)
      draw_roof(io, (noise(index * 3 + 1, salt) * ROOF_TYPES).to_i, body_x, body_w, top, height)
      if @antenna.includes?(user.login)
        io << %(      <rect x="#{SVG.num(x + wall / 2 - ANTENNA_W / 2)}" y="#{SVG.num(top - ANTENNA_H)}" width="#{SVG.num(ANTENNA_W)}" height="#{SVG.num(ANTENNA_H)}"/>\n)
      end
      io << "    </g>\n"
      draw_windows(io, index, salt, x, top, height) if skyline.windows?
      io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x + PAD)}" y="#{SVG.num(top + ROOF_BAND + PAD)}" width="#{skyline.avatar_size}" height="#{skyline.avatar_size}" preserveAspectRatio="xMidYMid slice")
      io << %( clip-path="url(##{CLIP_ID})") if clipped
      io << "/>\n"
      if skyline.show_names?
        label(io, truncate(user.name, skyline.truncate), x + wall / 2, baseline + GROUND_H + 12)
      end
      io << "  </a>\n"
    end

    # Six roof silhouettes, all confined to the top ROOF_BAND so the avatar
    # always sits against the full-width body underneath, and every one of
    # them reaches `top` so a building measures its full height.
    private def draw_roof(io : String::Builder, pick : Int32, x : Float64, wall : Float64,
                          top : Float64, height : Float64) : Nil
      body = ->(from : Float64) do
        io << %(      <rect x="#{SVG.num(x)}" y="#{SVG.num(top + from)}" width="#{SVG.num(wall)}" height="#{SVG.num(height - from)}"/>\n)
      end
      crown = ->(cx : Float64, cw : Float64, cy : Float64, ch : Float64) do
        io << %(      <rect x="#{SVG.num(cx)}" y="#{SVG.num(top + cy)}" width="#{SVG.num(cw)}" height="#{SVG.num(ch)}"/>\n)
      end

      case pick
      when 1
        # Set-back parapet: a slightly narrower crown over the full body.
        body.call(ROOF_BAND)
        crown.call(x + 3, wall - 6, 0.0, ROOF_BAND)
      when 2
        # Penthouse: a half-width cabin on the roof.
        body.call(ROOF_BAND)
        crown.call(x + wall / 4, wall / 2, 0.0, ROOF_BAND)
      when 3
        # Ziggurat: two steps up to a narrow top.
        body.call(ROOF_BAND)
        crown.call(x + 2, wall - 4, ROOF_BAND / 2, ROOF_BAND / 2)
        crown.call(x + wall / 4, wall / 2, 0.0, ROOF_BAND / 2)
      when 4
        # Crenellated parapet: a block on each shoulder.
        body.call(ROOF_BAND)
        crown.call(x, wall * 0.28, 0.0, ROOF_BAND)
        crown.call(x + wall * 0.72, wall * 0.28, 0.0, ROOF_BAND)
      when 5
        # Twin pylons, the cooling-stack look.
        body.call(ROOF_BAND)
        crown.call(x + wall * 0.18, 5.0, 0.0, ROOF_BAND)
        crown.call(x + wall * 0.82 - 5.0, 5.0, 0.0, ROOF_BAND)
      else
        # Flat.
        body.call(0.0)
      end
    end

    # Panes on a grid derived from the avatar's own column count, in the zone
    # between the avatar's floor and the building's, so avoiding the face is
    # a property of the geometry rather than a check. Each building draws one
    # glazing — square offices or long ribbon windows — from the same lottery
    # as its roof. A short tower whose zone holds no full row stays solid.
    private def draw_windows(io : String::Builder, index : Int32, salt : UInt64,
                             x : Float64, top : Float64, height : Float64) : Nil
      size = @config.skyline.avatar_size
      cols = (size // 12).clamp(2, 6)
      pitch = size / cols
      zone_top = top + ROOF_BAND + PAD + size + PAD
      zone = top + height - PAD - zone_top
      floors = (zone / pitch).floor.to_i
      return if floors < 1

      # A tower that wants more rows than this gets taller storeys instead of
      # more of them: the glazing still fills the wall exactly, but a small
      # `avatar_size` against a big `max_height` can no longer turn one wall
      # into hundreds of rows of 2px specks — which read as noise anyway, and
      # which a crowd multiplies into a document of a third of a million
      # rectangles. Constellation caps its dust for the same reason.
      storey = pitch
      if floors > FLOOR_CAP
        floors = FLOOR_CAP
        storey = zone / floors
      end

      ribbon = noise(index * 3 + 2, salt) < 0.5
      pane_w = ribbon ? pitch * 0.62 : pitch / 2
      pane_h = ribbon ? storey * 0.34 : storey / 2
      off_x = ribbon ? pitch * 0.19 : pitch / 4
      off_y = ribbon ? storey * 0.33 : storey / 4

      pane_salt = salt &+ index.to_u64 &* 7919_u64
      lit = [] of {Float64, Float64}
      unlit = [] of {Float64, Float64}
      floors.times do |floor|
        cols.times do |column|
          pane_x = x + PAD + column * pitch + off_x
          pane_y = zone_top + floor * storey + off_y
          state = noise(floor * cols + column, pane_salt)
          (state < LIT_RATIO ? lit : unlit) << {pane_x, pane_y}
        end
      end

      draw_panes(io, lit, pane_w, pane_h, "lit")
      draw_panes(io, unlit, pane_w, pane_h, "dark")
    end

    # One group per state, so the fill is inherited rather than repeated.
    private def draw_panes(io : String::Builder, panes : Array({Float64, Float64}),
                           pane_w : Float64, pane_h : Float64, state : String) : Nil
      return if panes.empty?
      io << %(    <g #{window_paint(state)}>\n)
      panes.each do |(x, y)|
        io << %(      <rect x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(pane_w)}" height="#{SVG.num(pane_h)}"/>\n)
      end
      io << "    </g>\n"
    end

    private def height_for(login : String) : Float64
      @heights[login]? || @config.skyline.min_height.to_f
    end

    # The gutter this section is drawn with — grid's document-wide measure, so
    # every row of every section starts its buildings on the same left edge.
    private def gutter_for(users : Array(EmbeddedUser)) : Float64
      Math.max(@gutter, overhang(users))
    end

    private def overhang(users : Array(Labelled)) : Float64
      skyline = @config.skyline
      return 0.0 unless skyline.show_names?
      widest = users.max_of? { |user| text_width(truncate(user.name, skyline.truncate), 11.0) }
      return 0.0 unless widest
      Math.max(widest - (skyline.avatar_size + 2 * PAD), 0.0) / 2
    end

    private def inks
      mode.dark? ? DARK_INKS : LIGHT_INKS
    end

    private def building_paint : String
      mode.auto? ? %(class="mural-building") : %(fill="#{inks[:building]}")
    end

    private def ground_paint : String
      mode.auto? ? %(class="mural-ground") : %(fill="#{inks[:ground]}")
    end

    private def window_paint(state : String) : String
      return %(class="mural-window-#{state}") if mode.auto?
      %(fill="#{state == "lit" ? inks[:lit] : inks[:unlit]}")
    end
  end
end
