module ContributorMural::Renderers
  # A night sky: every contributor is a star whose size and glow follow their
  # rank, near neighbours join up into constellations, and a scatter of tiny
  # dust stars fills the dark between them. Placement is a hash-jittered
  # lattice — the cells are disjoint, so however the jitter lands no star can
  # touch another — with the occupied cells themselves picked by hash, which
  # is what makes the sky read as scattered rather than ruled.
  class Constellation < Renderer
    CLIP_ID = "star-clip"
    GLOW_ID = "star-glow"

    # Halo radius as a multiple of the star's own: the tail glows a little
    # past its rim, the top of the ranking half again as far. The canvas
    # padding is derived from HALO_MAX, so the brightest halo just fits.
    HALO_MIN = 1.3
    HALO_MAX = 1.8

    # Longest constellation edge kept, in cell pitches. The spanning tree
    # connects everything; pruning it back to its short edges is what breaks
    # the sky into separate constellations instead of one long snake.
    LINE_REACH = 2.4
    # How far a line stops short of the rim it points at.
    LINE_INSET = 4.0
    # A trimmed stub shorter than this reads as a speck, not a line.
    LINE_MIN = 8.0

    # Hard ceiling on dust per section, so a wall of hundreds cannot swell
    # the file with thousands of circles.
    DUST_CAP = 1500
    # Dust never comes closer to an avatar's rim than this.
    DUST_CLEARANCE = 3.0

    private alias Star = NamedTuple(user: EmbeddedUser, x: Float64, y: Float64, size: Float64)

    @sizes = {} of String => Float64
    @glows = {} of String => Float64
    @section = 0

    # Rank drives size and glow exactly like the spiral's taper: a power curve
    # below 1 drops quickly among the leaders and then runs nearly flat, so
    # the long tail stays a uniform field of faint stars.
    def prepare(users : Array(ResolvedUser)) : Nil
      constellation = @config.constellation
      ranked = users.sort_by { |user| {-user.weight, user.login.downcase} }
      last = Math.max(ranked.size - 1, 1)
      ranked.each_with_index do |user, index|
        t = (index / last.to_f) ** 0.45
        size = constellation.max_size - (constellation.max_size - constellation.min_size) * t
        @sizes[user.login] = size * user.scale
        @glows[user.login] = 1.0 - t
      end
    end

    def fetch_size(user : ResolvedUser) : Int32
      (size_for(user.login) * 2).ceil.to_i
    end

    # Cell shuffles and dust are salted by section.
    protected def reset_document : Nil
      @section = 0
    end

    protected def defs(io : String::Builder) : Nil
      io << "  <defs>\n"
      io << %(    <clipPath id="#{CLIP_ID}" clipPathUnits="objectBoundingBox"><circle cx="0.5" cy="0.5" r="0.5"/></clipPath>\n)
      io << %(    <radialGradient id="#{GLOW_ID}">\n)
      io << %(      <stop offset="0" #{glow_paint} stop-opacity="0.9"/>\n)
      io << %(      <stop offset="0.5" #{glow_paint} stop-opacity="0.35"/>\n)
      io << %(      <stop offset="1" #{glow_paint} stop-opacity="0"/>\n)
      io << "    </radialGradient>\n"
      io << "  </defs>\n"
    end

    protected def style_rules(palette : Palette) : String
      constellation = @config.constellation
      dark = palette == theme.dark_palette
      String.build do |rules|
        rules << ".mural-glow{stop-color:#{palette.title_color}}"
        rules << ".mural-halo{opacity:#{dark ? "0.9" : "0.4"}}"
        rules << ".mural-dust{fill:#{palette.label_color}}" if constellation.dust > 0
        rules << ".mural-line{stroke:#{palette.label_color}}" if constellation.lines?
      end
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      return {16.0, 16.0} if users.empty?
      width, height, _cols, _pitch, _pad = frame(users)
      {width, height}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      return if users.empty?

      constellation = @config.constellation
      width, height, cols, pitch, pad = frame(users)
      stars = place(users, cols, pitch, pad)

      # Back to front: dust, then lines, then every halo, then every avatar —
      # a halo bleeding past its cell may tint the background, never a
      # neighbour's face.
      draw_dust(io, stars, width, height, pad, y_offset) if constellation.dust > 0
      draw_lines(io, stars, pitch, y_offset) if constellation.lines?

      stars.each do |star|
        halo = star[:size] / 2 * (HALO_MIN + (HALO_MAX - HALO_MIN) * glow_for(star[:user].login))
        io << %(  <circle cx="#{SVG.num(star[:x])}" cy="#{SVG.num(star[:y] + y_offset)}" r="#{SVG.num(halo)}" fill="url(##{GLOW_ID})" #{halo_paint}/>\n)
      end

      stars.each do |star|
        user = star[:user]
        size = star[:size]
        linked(io, user) do
          avatar(io, user, star[:x] - size / 2, star[:y] - size / 2 + y_offset, size, size, CLIP_ID)
        end
      end

      @section += 1
    end

    # {width, height, cols, pitch, pad}, closed form. The pitch is at least
    # the widest star plus the gap — by the division when a column fits, by
    # the clamp when even one does not — so every cell can hold its star with
    # `gap` of clearance to spare. The lattice never has more columns than
    # people: the shuffle deals cells over the whole lattice, and a column
    # the width formula did not pay for would put its star past the edge of
    # the document. Pure: the base class sizes every section before drawing
    # any of them.
    private def frame(users : Array(EmbeddedUser)) : {Float64, Float64, Int32, Float64, Float64}
      constellation = @config.constellation
      count = users.size
      widest = users.max_of { |user| size_for(user.login) }
      pad = (HALO_MAX - 1.0) / 2 * widest
      inner = Math.max(constellation.width - 2 * pad, 1.0)
      raw = Math.max((inner / (widest + constellation.gap)).to_i, 1)
      pitch = raw == 1 ? Math.max(inner, widest + constellation.gap) : inner / raw
      cols = Math.min(raw, count)
      rows = (count + cols - 1) // cols
      {cols * pitch + 2 * pad, rows * pitch + 2 * pad, cols, pitch, pad}
    end

    # Every star keeps to its own cell, inset by half the gap on each side:
    # the jitter spends only the room the cell has left over once the star and
    # the gap are paid for, so two stars are always a full `gap` apart — for
    # any config, any count, and any `scale`. Which cells are occupied is a
    # hashed shuffle of all of them, so the holes land anywhere rather than
    # always at the bottom edge. List order is kept: only positions permute.
    private def place(users : Array(EmbeddedUser), cols : Int32, pitch : Float64, pad : Float64) : Array(Star)
      constellation = @config.constellation
      rows = (users.size + cols - 1) // cols
      shuffle_salt = @section.to_u64 &* 7919_u64
      jitter_salt = @section.to_u64 &* 104729_u64 &+ 1
      cells = (0...rows * cols).to_a.sort_by! { |cell| {noise(cell, shuffle_salt), cell} }

      users.map_with_index do |user, index|
        size = size_for(user.login)
        row, col = cells[index].divmod(cols)
        free = Math.max(pitch - size - constellation.gap, 0.0)
        x = pad + (col + 0.5) * pitch + (noise(index * 2, jitter_salt) - 0.5) * constellation.jitter * free
        y = pad + (row + 0.5) * pitch + (noise(index * 2 + 1, jitter_salt) - 0.5) * constellation.jitter * free
        {user: user, x: x, y: y, size: size}
      end
    end

    private def draw_lines(io : String::Builder, stars : Array(Star), pitch : Float64, y_offset : Float64) : Nil
      segments = [] of {Float64, Float64, Float64, Float64}
      constellation_edges(stars, pitch).each do |(a, b)|
        from = stars[a]
        to = stars[b]
        dx = to[:x] - from[:x]
        dy = to[:y] - from[:y]
        span = Math.sqrt(dx * dx + dy * dy)
        next if span < 1e-9
        # Stop short of both rims, so a line points at a star without ever
        # running underneath its glow.
        head = from[:size] / 2 + LINE_INSET
        tail = to[:size] / 2 + LINE_INSET
        next if span - head - tail < LINE_MIN
        ux = dx / span
        uy = dy / span
        segments << {from[:x] + ux * head, from[:y] + uy * head, to[:x] - ux * tail, to[:y] - uy * tail}
      end
      return if segments.empty?

      io << %(  <g fill="none" stroke-width="1" stroke-linecap="round" opacity="0.4" #{line_paint}>\n)
      segments.each do |(x1, y1, x2, y2)|
        io << %(    <line x1="#{SVG.num(x1)}" y1="#{SVG.num(y1 + y_offset)}" x2="#{SVG.num(x2)}" y2="#{SVG.num(y2 + y_offset)}"/>\n)
      end
      io << "  </g>\n"
    end

    # Prim's spanning tree over the star centres, pruned back to short edges:
    # near neighbours connect, distant ones stay apart, and what remains reads
    # as separate constellations. Ties in the float distances are settled by
    # visiting order, so the tree is the same tree every render.
    private def constellation_edges(stars : Array(Star), pitch : Float64) : Array({Int32, Int32})
      count = stars.size
      return [] of {Int32, Int32} if count < 2

      reach = (LINE_REACH * pitch) ** 2
      in_tree = Array.new(count, false)
      best = Array.new(count) { |index| index.zero? ? 0.0 : distance2(stars[0], stars[index]) }
      from = Array.new(count, 0)
      in_tree[0] = true

      edges = [] of {Int32, Int32}
      (count - 1).times do
        pick = -1
        count.times do |index|
          next if in_tree[index]
          pick = index if pick < 0 || best[index] < best[pick]
        end
        break if pick < 0

        in_tree[pick] = true
        edges << {from[pick], pick} if best[pick] <= reach
        count.times do |index|
          next if in_tree[index]
          squared = distance2(stars[pick], stars[index])
          if squared < best[index]
            best[index] = squared
            from[index] = pick
          end
        end
      end
      edges
    end

    # Slots that land under a star are simply skipped — the count coming out a
    # little under `dust` per person is deterministic too. Two depths of dust:
    # the smaller specks sit fainter, which is what gives the sky its distance.
    private def draw_dust(io : String::Builder, stars : Array(Star), width : Float64, height : Float64,
                          pad : Float64, y_offset : Float64) : Nil
      salt = @section.to_u64 &* 15485863_u64 &+ 2
      near = [] of {Float64, Float64, Float64}
      far = [] of {Float64, Float64, Float64}
      Math.min(stars.size * @config.constellation.dust, DUST_CAP).times do |slot|
        x = pad / 2 + noise(slot * 3, salt) * (width - pad)
        y = pad / 2 + noise(slot * 3 + 1, salt) * (height - pad)
        covered = stars.any? do |star|
          dx = star[:x] - x
          dy = star[:y] - y
          limit = star[:size] / 2 + DUST_CLEARANCE
          dx * dx + dy * dy < limit * limit
        end
        next if covered
        radius = 0.5 + noise(slot * 3 + 2, salt) * 0.7
        (radius < 0.85 ? far : near) << {x, y, radius}
      end

      draw_speck_layer(io, far, 0.25, y_offset)
      draw_speck_layer(io, near, 0.5, y_offset)
    end

    private def draw_speck_layer(io : String::Builder, specks : Array({Float64, Float64, Float64}),
                                 opacity : Float64, y_offset : Float64) : Nil
      return if specks.empty?
      io << %(  <g fill-opacity="#{SVG.num(opacity)}" #{dust_paint}>\n)
      specks.each do |(x, y, radius)|
        io << %(    <circle cx="#{SVG.num(x)}" cy="#{SVG.num(y + y_offset)}" r="#{SVG.num(radius)}"/>\n)
      end
      io << "  </g>\n"
    end

    private def distance2(a : Star, b : Star) : Float64
      dx = a[:x] - b[:x]
      dy = a[:y] - b[:y]
      dx * dx + dy * dy
    end

    private def size_for(login : String) : Float64
      @sizes[login]? || @config.constellation.max_size.to_f
    end

    private def glow_for(login : String) : Float64
      @glows[login]? || 1.0
    end

    private def glow_paint : String
      mode.auto? ? %(class="mural-glow") : %(stop-color="#{SVG.escape(palette.title_color)}")
    end

    # The halo carries the glow in both themes, but a dark sky takes much more
    # of it than a white page does.
    private def halo_paint : String
      mode.auto? ? %(class="mural-halo") : %(opacity="#{mode.dark? ? "0.9" : "0.4"}")
    end

    private def dust_paint : String
      mode.auto? ? %(class="mural-dust") : %(fill="#{SVG.escape(palette.label_color)}")
    end

    private def line_paint : String
      mode.auto? ? %(class="mural-line") : %(stroke="#{SVG.escape(palette.label_color)}")
    end
  end
end
