module ContributorMural::Renderers
  # Stained glass: avatars clipped into irregular cells that tile a rectangle
  # edge to edge, separated by a hairline lead. Seeds sit on a jittered
  # lattice, and each cell is the block rectangle cut down by one half-plane
  # per other seed — a power (Laguerre) diagram, so weight widens a cell
  # without moving it.
  #
  # The lead is a true inset rather than a stroke: pulling every cutting line
  # back by half the gap leaves neighbouring cells exactly `gap` apart with the
  # page showing through, which themes itself for free under a transparent
  # background.
  class Voronoi < Renderer
    # These ids land in a generated file that consumers run spell checkers
    # over, so the prefix has to stay clear of dictionary near-misses: an
    # abbreviation of "voronoi" reads as a misspelling of "for" to
    # crate-ci/typos, once per cell, in a file nobody can correct by hand.
    CLIP_PREFIX = "vcell-"

    # Cap on how far weight may push a boundary, as a fraction of the closest
    # seed pair. At 0.5 every cell provably still contains a disc of radius
    # 0.25 * d_min around its own seed, so no cell can be squeezed to nothing
    # however lopsided the weights are (see the "no cell collapses" spec).
    ALPHA_MAX = 0.5

    # Second guard on the same invariant, expressed where it is easiest to
    # read: the boundary between two seeds may never travel past 70% of the
    # way toward either of them.
    BISECTOR_REACH = 0.4

    # The closest a boundary can come to its own seed, as a fraction of the
    # distance to the other one — the near end of the interval `BISECTOR_REACH`
    # pins down. This is what lets a cell rule a distant seed out without
    # clipping against it.
    MIN_REACH = (1.0 - BISECTOR_REACH) / 2.0

    private alias Point = {Float64, Float64}

    private record Seed, x : Float64, y : Float64, power : Float64

    @ranks = {} of String => Float64
    @section = 0
    @next_cell = 0
    @headcount = 0

    # Dense rank over the *distinct* weight values, not over users: a
    # contributor with 1000x the commits lands at the top of the scale exactly
    # like one with 2x, so an outlier can never distort the geometry. All-equal
    # weights leave the table empty, which reduces to a plain Voronoi.
    def prepare(users : Array(ResolvedUser)) : Nil
      @headcount = users.size
      distinct = users.map(&.weight).uniq!.sort!
      return if distinct.size <= 1

      span = (distinct.size - 1).to_f
      positions = {} of Int32 => Float64
      distinct.each_with_index { |weight, index| positions[weight] = index / span }
      users.each { |user| @ranks[user.login] = positions[user.weight] }
    end

    def fetch_size(user : ResolvedUser) : Int32
      voronoi = @config.voronoi
      # 2x for high-DPI, and half again because a heavy cell runs wider than
      # the nominal pitch and the image is squared to its longer side.
      (voronoi.width.to_f / loosest_row * 3).ceil.to_i
    end

    # Cell ids are numbered across the whole document, so a renderer reused for
    # a second document has to start over.
    def render(groups : Array({String?, Array(EmbeddedUser)})) : String
      @section = 0
      @next_cell = 0
      super
    end

    protected def title_inset : Float64
      0.0
    end

    protected def style_rules(palette : Palette) : String
      @config.voronoi.outline? ? ".mural-cell{stroke:#{palette.label_color}}" : ""
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      width, height, _rows = frame(users.size)
      {width, height}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      return if users.empty?

      width, height, rows = frame(users.size)
      seeds = place(users, width, height, rows)
      return if seeds.empty?

      # Two buffers the clipper alternates between. Building a cell is a run of
      # half-plane cuts, each of which used to allocate the polygon afresh —
      # thousands of throwaway arrays per cell, and the bulk of the render for
      # a wall of any size.
      scratch = {Array(Point).new(8), Array(Point).new(8)}
      cells = seeds.each_index.map do |index|
        polygon = cell(seeds, index, width, height, scratch)
        polygon.size >= 3 ? polygon : fallback(seeds[index])
      end.to_a
      first = @next_cell

      io << "  <defs>\n"
      cells.each do |polygon|
        io << %(    <clipPath id="#{CLIP_PREFIX}#{@next_cell}"><polygon points="#{outline(polygon, y_offset)}"/></clipPath>\n)
        @next_cell += 1
      end
      io << "  </defs>\n"

      users.each_with_index do |user, index|
        x, y, side = cover(cells[index])
        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y + y_offset)}" width="#{SVG.num(side)}" height="#{SVG.num(side)}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{CLIP_PREFIX}#{first + index})"/>\n)
        io << "  </a>\n"
      end

      if @config.voronoi.outline?
        cells.each do |polygon|
          io << %(  <polygon points="#{outline(polygon, y_offset)}" fill="none" stroke-width="1" #{cell_paint}/>\n)
        end
      end

      @section += 1
    end

    # Columns the configured pitch asks for, independent of how many people
    # turned up.
    private def column_target : Int32
      voronoi = @config.voronoi
      Math.max(1, (voronoi.width + voronoi.cell_size // 2) // voronoi.cell_size)
    end

    # The fewest cells a row can hold, which is the widest a cell can get —
    # what the avatar has to be fetched large enough to fill. A fixed row count
    # divides the crowd `prepare` saw; without one the pitch rules, and a row
    # never holds fewer than the columns that pitch asks for.
    private def loosest_row : Int32
      columns = column_target
      rows = @config.voronoi.rows
      return columns unless rows && @headcount.positive?
      Math.min(columns, Math.max((@headcount + rows - 1) // rows, 1))
    end

    # {width, height, rows} in closed form. The base class sizes every section
    # before drawing any of them, so this has to be cheap and must never touch
    # the id counters.
    private def frame(count : Int32) : {Float64, Float64, Int32}
      return {16.0, 16.0, 0} if count.zero?

      if fixed = @config.voronoi.rows
        # An explicit row count says how the wall divides, so the slab keeps
        # its full width and the cells widen or narrow to fill it — that is
        # the whole point of asking for a row count rather than a pitch.
        rows = Math.min(fixed, count)
        width = @config.voronoi.width.to_f
      else
        columns = column_target
        rows = Math.min(Math.max((count + columns // 2) // columns, 1), count)
        pitch = @config.voronoi.width.to_f / columns
        # A list shorter than one row shrinks the slab instead of stretching it.
        width = count < columns ? count * pitch : @config.voronoi.width.to_f
      end
      # Rows tall enough that the average cell comes out square.
      {width, width * rows * rows / count, rows}
    end

    # Rows differ in length by at most one, so a short last row still spans the
    # full width rather than leaving one stretched cell behind.
    private def row_counts(count : Int32, rows : Int32) : Array(Int32)
      base = count // rows
      extra = count % rows
      Array.new(rows) { |row| base + (row < extra ? 1 : 0) }
    end

    private def place(users : Array(EmbeddedUser), width : Float64, height : Float64, rows : Int32) : Array(Seed)
      return [] of Seed if rows.zero?

      voronoi = @config.voronoi
      salt = @section.to_u64 &* 104729_u64
      cell_h = height / rows
      spots = [] of Point
      index = 0
      row_counts(users.size, rows).each_with_index do |per_row, row|
        cell_w = width / per_row
        per_row.times do |column|
          x = (column + 0.5) * cell_w + (noise(index * 2, salt) - 0.5) * voronoi.jitter * cell_w
          y = (row + 0.5) * cell_h + (noise(index * 2 + 1, salt) - 0.5) * voronoi.jitter * cell_h
          spots << {x, y}
          index += 1
        end
      end

      ceiling = ALPHA_MAX * voronoi.weight_influence * closest_pair(spots)
      spots.map_with_index do |(x, y), position|
        Seed.new(x, y, ceiling * (@ranks[users[position].login]? || 0.0))
      end
    end

    private def closest_pair(spots : Array(Point)) : Float64
      closest = Float64::MAX
      spots.each_with_index do |a, i|
        (i + 1...spots.size).each do |j|
          b = spots[j]
          dx = a[0] - b[0]
          dy = a[1] - b[1]
          squared = dx * dx + dy * dy
          closest = squared if squared < closest
        end
      end
      closest == Float64::MAX ? 0.0 : closest
    end

    private def cell(seeds : Array(Seed), index : Int32, width : Float64, height : Float64,
                     scratch : {Array(Point), Array(Point)}) : Array(Point)
      inset = @config.voronoi.gap / 2.0
      me = seeds[index]
      polygon, spare = scratch
      polygon.clear
      polygon << {0.0, 0.0} << {width, 0.0} << {width, height} << {0.0, height}
      # Once the near neighbours have been cut away, most of the wall is too
      # far off to reach what is left of this cell, and clipping against it
      # would copy the polygon out unchanged. Every seed used to be clipped
      # against every other one.
      limit = reach_limit(polygon, me, inset)

      seeds.each_with_index do |other, position|
        next if position == index
        nx = other.x - me.x
        ny = other.y - me.y
        squared = nx * nx + ny * ny
        next if squared < 1e-12
        next if squared > limit

        # Radical axis of the two power circles. Clamping the weight term is
        # what keeps the boundary inside [0.3, 0.7] of the way across, so the
        # cell can never be cut away entirely.
        delta = (me.power - other.power).clamp(-BISECTOR_REACH * squared, BISECTOR_REACH * squared)
        offset = nx * me.x + ny * me.y + (squared + delta) / 2
        clip(polygon, spare, nx, ny, offset - inset * Math.sqrt(squared))
        polygon, spare = spare, polygon
        break if polygon.size < 3
        limit = reach_limit(polygon, me, inset)
      end
      # The buffers belong to the caller's whole run of cells, so the one cell
      # that is kept has to be a copy.
      polygon.dup
    end

    # How far a seed may sit and still cut `polygon`, squared.
    #
    # The clamp in `cell` keeps a boundary at least `MIN_REACH * distance` away
    # from its own seed, and the lead pulls it back by `inset` on top of that.
    # So a seed whose boundary would land beyond the polygon's own farthest
    # vertex leaves every vertex on the keep side — an exact no-op, not an
    # approximation, which is why skipping it draws the same picture. The
    # margin keeps a borderline seed on the clipping side of the decision,
    # where a wasted copy costs nothing and a wrong skip would show.
    private def reach_limit(polygon : Array(Point), me : Seed, inset : Float64) : Float64
      farthest = polygon.max_of do |(x, y)|
        dx = x - me.x
        dy = y - me.y
        dx * dx + dy * dy
      end
      bound = (Math.sqrt(farthest) + inset) / MIN_REACH
      bound * bound * (1.0 + 1e-9)
    end

    # Sutherland-Hodgman: keeps the `a * x + b * y <= c` side. Convex in,
    # convex out, which is why a run of these builds the cell exactly. Writes
    # into `target` rather than returning a fresh array, so a cell cut a
    # thousand times still works out of two buffers.
    private def clip(source : Array(Point), target : Array(Point),
                     a : Float64, b : Float64, c : Float64) : Nil
      target.clear
      if source.size < 3
        target.concat(source)
        return
      end

      # Each vertex's side is the next vertex's `before`, so it is carried
      # rather than recomputed — the same value either way.
      previous = source.last
      before = a * previous[0] + b * previous[1] - c
      source.each do |current|
        now = a * current[0] + b * current[1] - c
        if now <= 0
          target << cut(previous, current, before, now) if before > 0
          target << current
        elsif before <= 0
          target << cut(previous, current, before, now)
        end
        previous = current
        before = now
      end
    end

    # Only reached when the two distances straddle the line, so the
    # denominator cannot be zero.
    private def cut(from : Point, to : Point, before : Float64, now : Float64) : Point
      ratio = before / (before - now)
      {from[0] + (to[0] - from[0]) * ratio, from[1] + (to[1] - from[1]) * ratio}
    end

    # Should never be reached under a valid config; a cell with no area would
    # otherwise take its avatar's link and tooltip down with it.
    private def fallback(seed : Seed) : Array(Point)
      half = Math.max(@config.voronoi.gap.to_f, 1.0)
      [
        {seed.x - half, seed.y - half}, {seed.x + half, seed.y - half},
        {seed.x + half, seed.y + half}, {seed.x - half, seed.y + half},
      ] of Point
    end

    # A square covering the cell, centred on its area centroid rather than its
    # bounding box: for a wedge-shaped cell the bounding-box centre lands in
    # the part of the avatar the clip path throws away.
    private def cover(polygon : Array(Point)) : {Float64, Float64, Float64}
      cx, cy = centroid(polygon)
      reach = polygon.max_of { |(x, y)| Math.max((x - cx).abs, (y - cy).abs) }
      {cx - reach, cy - reach, reach * 2}
    end

    private def centroid(polygon : Array(Point)) : Point
      twice_area = 0.0
      cx = 0.0
      cy = 0.0
      polygon.each_with_index do |current, index|
        following = polygon[(index + 1) % polygon.size]
        cross = current[0] * following[1] - following[0] * current[1]
        twice_area += cross
        cx += (current[0] + following[0]) * cross
        cy += (current[1] + following[1]) * cross
      end
      if twice_area.abs < 1e-9
        count = polygon.size.to_f
        return {polygon.sum(&.[](0)) / count, polygon.sum(&.[](1)) / count}
      end
      {cx / (3 * twice_area), cy / (3 * twice_area)}
    end

    # Clipping routinely leaves vertices a few ULP apart that round to the same
    # two decimals. The zero-length edges are harmless to render but they make
    # golden diffs unreadable, so drop them here rather than in the geometry.
    private def outline(polygon : Array(Point), y_offset : Float64) : String
      parts = [] of String
      polygon.each do |(x, y)|
        part = "#{SVG.num(x)},#{SVG.num(y + y_offset)}"
        parts << part unless parts.last? == part
      end
      parts.pop if parts.size > 1 && parts.first == parts.last
      parts.join(' ')
    end

    private def cell_paint : String
      mode.auto? ? %(class="mural-cell") : %(stroke="#{SVG.escape(palette.label_color)}")
    end
  end
end
