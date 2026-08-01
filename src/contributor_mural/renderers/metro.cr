module ContributorMural::Renderers
  # A transit map: contributors are stations on a coloured route that snakes
  # across the wall — left to right, a rounded 180° turn, back again — in the
  # flat-colour idiom of the classic network diagrams. Each section is its own
  # line in its own colour, its title reading as the line's name, and the two
  # ends of a line carry the heavier ring of a terminus. With `role_lines`,
  # a section splits further: one line per role, named after it — and `weave`
  # interleaves those lines' rows so the routes genuinely cross one another,
  # the way a real network does.
  class Metro < Renderer
    CLIP_ID = "metro-clip"

    # Terminus ring stroke, as a multiple of the line's width. The ring's
    # inner edge stays flush with the avatar either way; a terminus is only
    # heavier on the outside.
    TERMINUS = 1.6
    # Vertical room reserved under each row for station names.
    LABEL_BLOCK = 18.0
    # The band a role-named line's title takes, and the air between lines.
    LINE_TITLE = 20.0
    LINE_GAP   = 18.0

    # Mid-lightness route colours that hold up on white and on GitHub's dark
    # background alike, so one palette serves every theme and every stroke is
    # a plain attribute — nothing for CSS or the rasterizer to miss. A ninth
    # line wraps around to the first colour.
    LINE_COLORS = %w[#e5484d #3b82f6 #30a46c #f76b15 #8e4ec6 #12a594 #d6409f #ad7f58]

    # Anyone whose label reaches the document, whether or not their avatar
    # has been fetched yet.
    private alias Labelled = ResolvedUser | EmbeddedUser
    private alias Line = {String?, Array(EmbeddedUser)}

    private record Metrics,
      outer : Float64,
      pitch_x : Float64,
      pitch_y : Float64,
      corner : Float64,
      margin : Float64,
      top : Float64,
      bottom : Float64

    @line = 0
    @half_label = 0.0

    # Half the widest station name in the whole document, measured once so
    # every section shares one margin and the columns stay in true.
    def prepare(users : Array(ResolvedUser)) : Nil
      @half_label = half_label(users)
    end

    def fetch_size(user : ResolvedUser) : Int32
      @config.metro.station_size * 2
    end

    # Line colours cycle across the document, so a renderer reused for a
    # second document has to start the cycle over.
    def render(groups : Array({String?, Array(EmbeddedUser)})) : String
      @line = 0
      super
    end

    # The line's name starts over the first station, not over the corner
    # loop's margin.
    protected def title_inset : Float64
      m = base_metrics(@half_label)
      m.margin - m.outer
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, Shape::Circle)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      return {16.0, 16.0} if users.empty?
      m = metrics(users)
      lines = buckets(users)
      return weave_size(lines, m) if weave?(lines)

      width = 0.0
      height = 0.0
      lines.each_with_index do |(role, members), index|
        height += LINE_GAP if index.positive?
        height += LINE_TITLE if role
        line_w, line_h = line_size(members.size, m)
        # A line is as wide as its serpentine or its name, whichever runs
        # further — the base class only measures section titles, not these.
        line_w = Math.max(line_w, m.margin - m.outer + text_width(role, 12.0) + 4) if role
        width = Math.max(width, line_w)
        height += line_h
      end
      {width, height}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      return if users.empty?

      m = metrics(users)
      lines = buckets(users)
      if weave?(lines)
        draw_weave(io, lines, m, y_offset)
        @line += lines.size
        return
      end

      y = y_offset
      lines.each_with_index do |(role, members), index|
        y += LINE_GAP if index.positive?
        color = LINE_COLORS[@line % LINE_COLORS.size]
        if role
          io << %(  <text x="#{SVG.num(m.margin - m.outer)}" y="#{SVG.num(y + 13)}" text-anchor="start" font-family="#{SVG.escape(theme.font_family)}" font-size="12" font-weight="600" fill="#{color}">#{SVG.escape(role)}</text>\n)
          y += LINE_TITLE
        end
        draw_line(io, members, m, y, color)
        y += line_size(members.size, m)[1]
        @line += 1
      end
    end

    # One stacked line: its route, its stations, its name labels.
    private def draw_line(io : String::Builder, users : Array(EmbeddedUser), m : Metrics,
                          y_offset : Float64, color : String) : Nil
      # A lone ringed station reads as a badge; a stub of track would read as
      # a mistake.
      draw_route(io, users.size, m, y_offset, color) if users.size > 1

      line = @config.metro.line_width.to_f
      spots = centers(users.size, m)
      last = users.size - 1
      users.each_with_index do |user, index|
        cx, cy = spots[index]
        ring = index.zero? || index == last ? TERMINUS * line : line
        draw_station(io, user, cx, cy + y_offset, ring, color, m)
      end
    end

    private def draw_station(io : String::Builder, user : EmbeddedUser, cx : Float64, cy : Float64,
                             ring : Float64, color : String, m : Metrics) : Nil
      metro = @config.metro
      size = metro.station_size.to_f
      io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
      io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
      io << %(    <image href="#{user.data_uri}" x="#{SVG.num(cx - size / 2)}" y="#{SVG.num(cy - size / 2)}" width="#{SVG.num(size)}" height="#{SVG.num(size)}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{CLIP_ID})"/>\n)
      io << %(    <circle cx="#{SVG.num(cx)}" cy="#{SVG.num(cy)}" r="#{SVG.num(size / 2 + ring / 2)}" fill="none" stroke="#{color}" stroke-width="#{SVG.num(ring)}"/>\n)
      if metro.show_names?
        label(io, truncate(user.name, metro.truncate), cx, cy + m.outer + 12)
      end
      io << "  </a>\n"
    end

    # --- Weave mode: the lines share one lattice and cross one another ---

    private def weave?(lines : Array(Line)) : Bool
      @config.metro.weave? && lines.size > 1
    end

    private def legend?(lines : Array(Line)) : Bool
      lines.any? { |(role, _members)| role }
    end

    private def weave_size(lines : Array(Line), m : Metrics) : {Float64, Float64}
      cols = lattice_columns(lines)
      slots = weave_slots(lines)
      height = (legend?(lines) ? LINE_TITLE : 0.0) + m.top + (slots.size - 1) * m.pitch_y + m.bottom
      width = 2 * m.margin + (cols - 1) * m.pitch_x
      # The legend runs left to right in one band; the document has to reach
      # its last entry.
      if legend?(lines)
        edge = m.margin - m.outer
        lines.each { |(role, _members)| edge += text_width(role, 12.0) + 18 if role }
        width = Math.max(width, edge - 18 + 4)
      end
      {width, height}
    end

    private def lattice_columns(lines : Array(Line)) : Int32
      lines.max_of { |(_role, members)| Math.min(@config.metro.columns, members.size) }
    end

    # How many lattice columns line `index` may ride. Every line past the
    # first gives up one column — a full-width line's turns swing outside the
    # map where there is nothing to cross, and the ceded column is what puts
    # the narrower lines' rails *inside* the others' rows. Each round of the
    # three-way stagger cedes one more, so line 3 does not land its rails on
    # line 0's exact x and read as one route changing colour.
    private def weave_cols(lines : Array(Line), index : Int32) : Int32
      lattice = lattice_columns(lines)
      wanted = Math.min(@config.metro.columns, lines[index][1].size)
      shrink = (index % 3 == 0 ? 0 : 1) + index // 3
      Math.max(Math.min(wanted, lattice - shrink), 1)
    end

    # Where line `index`'s span starts on the lattice: first line left, the
    # next right, the next centred, and around again — staggered ends are
    # what the crossings are made of.
    private def weave_start(lines : Array(Line), index : Int32) : Int32
      lattice = lattice_columns(lines)
      cols = weave_cols(lines, index)
      case index % 3
      when 1 then lattice - cols
      when 2 then (lattice - cols) // 2
      else        0
      end
    end

    # Right-aligned lines travel their first row right-to-left, so their
    # first turn drops on the interior side.
    private def mirrored?(index : Int32) : Bool
      index % 3 == 1
    end

    # The lines' rows dealt out in rounds — every line places its row 0, then
    # every line still running places its row 1, and so on. Interleaving is
    # the whole trick: a line reaching its next row has to travel down past
    # the rows the other lines put in between, and that is where it crosses
    # them.
    private def weave_slots(lines : Array(Line)) : Array({Int32, Int32})
      slots = [] of {Int32, Int32}
      row = 0
      loop do
        placed = slots.size
        lines.each_with_index do |(_role, members), index|
          cols = weave_cols(lines, index)
          slots << {index, row} if row < (members.size + cols - 1) // cols
        end
        break if slots.size == placed
        row += 1
      end
      slots
    end

    private def draw_weave(io : String::Builder, lines : Array(Line), m : Metrics, y_offset : Float64) : Nil
      metro = @config.metro
      slot_of = {} of {Int32, Int32} => Int32
      weave_slots(lines).each_with_index { |slot, index| slot_of[slot] = index }

      y = y_offset
      if legend?(lines)
        x = m.margin - m.outer
        lines.each_with_index do |(role, _members), index|
          next unless role
          io << %(  <text x="#{SVG.num(x)}" y="#{SVG.num(y + 13)}" text-anchor="start" font-family="#{SVG.escape(theme.font_family)}" font-size="12" font-weight="600" fill="#{weave_color(index)}">#{SVG.escape(role)}</text>\n)
          x += text_width(role, 12.0) + 18
        end
        y += LINE_TITLE
      end

      # A corner of half the station pitch drops every vertical rail exactly
      # midway between two station columns, so a rail can cross another
      # line's row without ever touching a ring — the validator's floor on
      # `gap` is what pays for that clearance.
      rail = m.pitch_x / 2
      line_width = metro.line_width.to_f

      lines.each_with_index do |(_role, members), index|
        cols = weave_cols(lines, index)
        rows = (members.size + cols - 1) // cols
        start = weave_start(lines, index)
        mirror = mirrored?(index)
        color = weave_color(index)
        row_y = ->(row : Int32) { y + m.top + slot_of[{index, row}] * m.pitch_y }
        col_x = ->(col : Int32) { m.margin + col * m.pitch_x }

        draw_weave_route(io, members.size, cols, rows, start, mirror, m, rail, row_y, col_x, color) if members.size > 1

        last = members.size - 1
        members.each_with_index do |user, position|
          row, spot = position.divmod(cols)
          cx = col_x.call(weave_col(start, cols, mirror, row, spot))
          ring = position.zero? || position == last ? TERMINUS * line_width : line_width
          draw_station(io, user, cx, row_y.call(row), ring, color, m)
        end
      end
    end

    # Lattice column of a line's `spot`th station in `row`, serpentine within
    # the line's own span.
    private def weave_col(start : Int32, cols : Int32, mirror : Bool, row : Int32, spot : Int32) : Int32
      leftward = mirror ? row.even? : row.odd?
      start + (leftward ? cols - 1 - spot : spot)
    end

    private def draw_weave_route(io : String::Builder, count : Int32, cols : Int32, rows : Int32,
                                 start : Int32, mirror : Bool, m : Metrics, rail : Float64,
                                 row_y : Proc(Int32, Float64), col_x : Proc(Int32, Float64),
                                 color : String) : Nil
      path = String.build do |track|
        track << "M#{SVG.num(col_x.call(weave_col(start, cols, mirror, 0, 0)))},#{SVG.num(row_y.call(0))}"
        current = weave_col(start, cols, mirror, 0, 0)
        rows.times do |row|
          in_row = Math.min(count - row * cols, cols)
          stop = weave_col(start, cols, mirror, row, in_row - 1)
          row_line = row_y.call(row)
          unless stop == current
            track << "L#{SVG.num(col_x.call(stop))},#{SVG.num(row_line)}"
            current = stop
          end
          next if row == rows - 1

          drop = row_y.call(row + 1)
          # The side this row's travel ends on — a single-station row still
          # turns on its travelling side.
          rightward = mirror ? row.odd? : row.even?
          radius = Math.min(rail, (drop - row_line) / 2)
          side = rightward ? radius : -radius
          sweep = rightward ? 1 : 0
          edge = col_x.call(stop)
          track << "A#{SVG.num(radius)} #{SVG.num(radius)} 0 0 #{sweep} #{SVG.num(edge + side)},#{SVG.num(row_line + radius)}"
          track << "L#{SVG.num(edge + side)},#{SVG.num(drop - radius)}" if drop - row_line - 2 * radius > 0
          track << "A#{SVG.num(radius)} #{SVG.num(radius)} 0 0 #{sweep} #{SVG.num(edge)},#{SVG.num(drop)}"
        end
      end
      io << %(  <path d="#{path}" fill="none" stroke="#{color}" stroke-width="#{@config.metro.line_width}" stroke-linecap="round"/>\n)
    end

    private def weave_color(index : Int32) : String
      LINE_COLORS[(@line + index) % LINE_COLORS.size]
    end

    # --- Shared plumbing ---

    # The lines a section carries. Without `role_lines` a section is one
    # line; with it, one per role in order of first appearance, and the
    # people who carry no role ride together on an unnamed one. List order
    # is kept within every line.
    private def buckets(users : Array(EmbeddedUser)) : Array(Line)
      return [{nil.as(String?), users}] unless @config.metro.role_lines?

      order = [] of String?
      grouped = {} of String? => Array(EmbeddedUser)
      users.each do |user|
        key = user.role
        unless grouped.has_key?(key)
          order << key
          grouped[key] = [] of EmbeddedUser
        end
        grouped[key] << user
      end
      order.map { |key| {key, grouped[key]} }
    end

    # {width, height} of one stacked line's serpentine, labels included.
    private def line_size(count : Int32, m : Metrics) : {Float64, Float64}
      cols = Math.min(@config.metro.columns, count)
      rows = (count + cols - 1) // cols
      {2 * m.margin + (cols - 1) * m.pitch_x, m.top + (rows - 1) * m.pitch_y + m.bottom}
    end

    private def metrics(users : Array(EmbeddedUser)) : Metrics
      base_metrics(Math.max(@half_label, half_label(users)))
    end

    private def base_metrics(inset : Float64) : Metrics
      metro = @config.metro
      size = metro.station_size.to_f
      line = metro.line_width.to_f
      outer = size / 2 + TERMINUS * line
      # The pitch funds a terminus ring on both sides, so `gap` stays the
      # clearance between rings it is documented to be even next to one.
      pitch_x = size + 2 * TERMINUS * line + metro.gap
      # A woven rail rides midway between two columns; where the names are on,
      # the midpoint also has to clear the label text either side of it.
      pitch_x = Math.max(pitch_x, 2 * inset + line + 4) if metro.weave?
      pitch_y = 2 * outer + metro.gap + (metro.show_names? ? LABEL_BLOCK : 0.0)
      # A full half-pitch corner degenerates the turn into a clean semicircle.
      corner = Math.min(pitch_y / 2, size)
      # Woven rails swing half a station pitch wide, and the margin has to
      # hold whichever loop is wider — stroke included.
      reach = metro.weave? ? Math.max(corner, pitch_x / 2) : corner
      margin = {reach + line / 2, outer, inset}.max + 2
      Metrics.new(
        outer: outer,
        pitch_x: pitch_x,
        pitch_y: pitch_y,
        corner: corner,
        margin: margin,
        top: outer + 2,
        bottom: outer + 2 + (metro.show_names? ? 16.0 : 0.0),
      )
    end

    # Station centres in list order: even rows run left to right, odd rows
    # come back — the serpentine the route itself follows.
    private def centers(count : Int32, m : Metrics) : Array({Float64, Float64})
      cols = Math.min(@config.metro.columns, count)
      Array.new(count) do |index|
        row, spot = index.divmod(cols)
        col = row.even? ? spot : cols - 1 - spot
        {m.margin + col * m.pitch_x, m.top + row * m.pitch_y}
      end
    end

    # The route as one path: a straight run through each row's centres, rows
    # joined by two quarter-circle arcs with a short vertical straight between
    # them when the rows sit further apart than the corner reaches. Even rows
    # turn on the right (clockwise, sweep 1), odd rows on the left.
    private def draw_route(io : String::Builder, count : Int32, m : Metrics, y_offset : Float64, color : String) : Nil
      cols = Math.min(@config.metro.columns, count)
      rows = (count + cols - 1) // cols
      near = m.margin
      far = m.margin + (cols - 1) * m.pitch_x
      straight = m.pitch_y - 2 * m.corner

      path = String.build do |track|
        track << "M#{SVG.num(near)},#{SVG.num(m.top + y_offset)}"
        current = near
        rows.times do |row|
          y = m.top + row * m.pitch_y + y_offset
          stop = stop_of(row, rows, count, cols, m)
          unless stop == current
            track << "L#{SVG.num(stop)},#{SVG.num(y)}"
            current = stop
          end
          next if row == rows - 1

          drop = y + m.pitch_y
          edge = row.even? ? far : near
          side = row.even? ? m.corner : -m.corner
          sweep = row.even? ? 1 : 0
          track << "A#{SVG.num(m.corner)} #{SVG.num(m.corner)} 0 0 #{sweep} #{SVG.num(edge + side)},#{SVG.num(y + m.corner)}"
          track << "L#{SVG.num(edge + side)},#{SVG.num(drop - m.corner)}" if straight > 0
          track << "A#{SVG.num(m.corner)} #{SVG.num(m.corner)} 0 0 #{sweep} #{SVG.num(edge)},#{SVG.num(drop)}"
          current = edge
        end
      end
      io << %(  <path d="#{path}" fill="none" stroke="#{color}" stroke-width="#{@config.metro.line_width}" stroke-linecap="round"/>\n)
    end

    # Where the track stops on this row: full rows run wall to wall, the last
    # row ends at its final station, whose round cap is the line's tail.
    private def stop_of(row : Int32, rows : Int32, count : Int32, cols : Int32, m : Metrics) : Float64
      if row < rows - 1
        row.even? ? m.margin + (cols - 1) * m.pitch_x : m.margin
      else
        short = count - (rows - 1) * cols
        steps = row.even? ? short - 1 : cols - short
        m.margin + steps * m.pitch_x
      end
    end

    private def half_label(users : Array(Labelled)) : Float64
      metro = @config.metro
      return 0.0 unless metro.show_names?
      widest = users.max_of? { |user| text_width(truncate(user.name, metro.truncate), 11.0) }
      (widest || 0.0) / 2
    end
  end
end
