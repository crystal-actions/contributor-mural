module ContributorMural::Renderers
  # The wall as a word: avatars fill the lit pixels of `text` set in a built-in
  # 5x7 face, and every pixel still waiting for someone shows a faint dot. So
  # the mural is legible from the first contributor and finishes itself as more
  # arrive.
  #
  # People are handed out one per pixel in reading order before any pixel gets
  # a second, and a pixel holding several splits into its own small grid. That
  # ordering is what keeps the word from ever looking emptier after someone
  # joins — the failure mode of resizing every pixel at once.
  class Stencil < Renderer
    CLIP_ID = "stencil-clip"

    GHOST_OPACITY = 0.38
    # Dot diameter as a share of its slot. A full-size disc reads as a wall of
    # broken images, but too small a dot stops joining up into strokes and the
    # word becomes unreadable — which is the whole job the ghosts are here for.
    GHOST_RATIO = 0.62

    private alias Pixel = {Int32, Int32}
    private alias Slot = {Int32, Int32}

    @sizes = {} of String => Float64
    @slot_orders = {} of Int32 => Array(Slot)
    @layout : {Array(Pixel), Int32, Int32}?

    # Sections spell the same word independently, so size each person against
    # their own group rather than the whole render.
    def prepare(users : Array(ResolvedUser)) : Nil
      pixels, _columns, _rows = layout
      capacity = pixels.size
      return if capacity.zero?

      users.group_by(&.group).each_value do |members|
        seats(members.size, capacity).each_with_index do |(pixel, _pass), index|
          side = grid_of(members_at(pixel, members.size, capacity))
          @sizes[members[index].login] = @config.stencil.pixel_size / side.to_f
        end
      end
    end

    def fetch_size(user : ResolvedUser) : Int32
      (size_for(user.login) * 2).ceil.to_i
    end

    protected def title_inset : Float64
      @config.stencil.gap.to_f
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, @config.stencil.shape)
    end

    protected def style_rules(palette : Palette) : String
      @config.stencil.ghosts? ? ".mural-ghost{fill:#{palette.label_color}}" : ""
    end

    # Depends only on the text and the pixel geometry, so a section of six and
    # a section of six hundred come out exactly the same size.
    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      stencil = @config.stencil
      _pixels, columns, rows = layout
      return {16.0, 16.0} if columns.zero?

      pitch = (stencil.pixel_size + stencil.gap).to_f
      {stencil.gap + columns * pitch, stencil.gap + rows * pitch}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      stencil = @config.stencil
      pixels, _columns, _rows = layout
      return if pixels.empty? || users.empty?

      capacity = pixels.size
      pitch = (stencil.pixel_size + stencil.gap).to_f
      draw_ghosts(io, pixels, users.size, pitch, y_offset) if stencil.ghosts?
      clipped = !stencil.shape.square?
      assignments = seats(users.size, capacity)

      users.each_with_index do |user, index|
        seat, pass = assignments[index]
        side = grid_of(members_at(seat, users.size, capacity))
        size = stencil.pixel_size / side.to_f
        x, y = spot(pixels[seat], slot_order(side)[pass], side, pitch, y_offset)

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(size)}" height="#{SVG.num(size)}" preserveAspectRatio="xMidYMid slice")
        io << %( clip-path="url(##{CLIP_ID})") if clipped
        io << "/>\n"
        io << "  </a>\n"
      end
    end

    # One dot per empty sub-slot, as a single group so the fill is inherited
    # rather than repeated a few hundred times.
    private def draw_ghosts(io : String::Builder, pixels : Array(Pixel), count : Int32,
                            pitch : Float64, y_offset : Float64) : Nil
      stencil = @config.stencil
      capacity = pixels.size
      slots = pixels.size.times.sum { |index| grid_of(members_at(index, count, capacity)) ** 2 }
      return if slots <= count

      io << %(  <g #{ghost_paint} opacity="#{SVG.num(GHOST_OPACITY)}">\n)
      pixels.each_with_index do |pixel, index|
        members = members_at(index, count, capacity)
        side = grid_of(members)
        size = stencil.pixel_size / side.to_f
        radius = Math.max(size * GHOST_RATIO / 2, 1.0)
        order = slot_order(side)
        (members...order.size).each do |position|
          x, y = spot(pixel, order[position], side, pitch, y_offset)
          io << %(    <circle cx="#{SVG.num(x + size / 2)}" cy="#{SVG.num(y + size / 2)}" r="#{SVG.num(radius)}"/>\n)
        end
      end
      io << "  </g>\n"
    end

    # {lit pixels in fill order, columns, rows}. Glyph by glyph left to right,
    # and row-major inside a glyph: capitals are read through their horizontal
    # features, so a half-filled letter scanned top-down still reads as itself.
    private def layout : {Array(Pixel), Int32, Int32}
      @layout ||= build_layout
    end

    private def build_layout : {Array(Pixel), Int32, Int32}
      stencil = @config.stencil
      lines = stencil.glyph_lines
      return {[] of Pixel, 0, 0} if lines.empty?

      widths = lines.map { |line| line_columns(line.size) }
      columns = widths.max
      rows = lines.size * StencilFont::HEIGHT + (lines.size - 1) * stencil.line_gap

      pixels = [] of Pixel
      lines.each_with_index do |line, line_index|
        # Whole-pixel centring keeps every line on the same lattice.
        left = (columns - widths[line_index]) // 2
        top = line_index * (StencilFont::HEIGHT + stencil.line_gap)
        line.each_with_index do |char, glyph_index|
          origin = left + glyph_index * (StencilFont::WIDTH + stencil.letter_spacing)
          StencilFont.glyph(char).each_with_index do |bits, row|
            bits.each_char_with_index do |bit, column|
              pixels << {origin + column, top + row} if bit == '#'
            end
          end
        end
      end
      {pixels, columns, rows}
    end

    private def line_columns(count : Int32) : Int32
      return 0 if count.zero?
      count * StencilFont::WIDTH + (count - 1) * @config.stencil.letter_spacing
    end

    # Pixel `index` holds this many people. Quotas differ by at most one, so
    # every pixel is served before any is served twice.
    #
    # Below capacity the served pixels are a contiguous prefix, which is what
    # writes the word left to right. Above it the surplus is spread evenly
    # instead: clumping the denser pixels would leave the front of the word
    # fine-grained and the back coarse, which reads as a broken render rather
    # than as texture.
    private def members_at(index : Int32, count : Int32, capacity : Int32) : Int32
      quota, surplus = count.divmod(capacity)
      return index < surplus ? 1 : 0 if quota.zero?
      quota + (((index + 1) * surplus) // capacity > (index * surplus) // capacity ? 1 : 0)
    end

    # {pixel, pass} for each user, in weight order. Everyone gets a pixel to
    # themselves before anyone shares one.
    private def seats(count : Int32, capacity : Int32) : Array({Int32, Int32})
      quota = count // capacity
      return Array.new(count) { |index| {index, 0} } if quota.zero?

      surplus = (0...capacity).select { |index| members_at(index, count, capacity) > quota }
      Array.new(count) do |index|
        if index < quota * capacity
          {index % capacity, index // capacity}
        else
          {surplus[index - quota * capacity], quota}
        end
      end
    end

    # Integer ceil(sqrt): `Math.sqrt(...).ceil` is a determinism hazard right
    # at the perfect squares, which is exactly where this is asked.
    private def grid_of(members : Int32) : Int32
      side = 1
      while side * side < members
        side += 1
      end
      side
    end

    # Checkerboard first, then the fill-in. Plain row-major would put every
    # half-full pixel's faces in its top row and band the whole word.
    private def slot_order(side : Int32) : Array(Slot)
      @slot_orders[side] ||= begin
        cells = [] of Slot
        side.times { |row| side.times { |column| cells << {row, column} } }
        cells.sort_by { |(row, column)| {(row + column) % 2, row, column} }
      end
    end

    # Sub-cells are a uniform 1/side scaling of the pixel's own cell, so a
    # pixel at side 1 and its neighbour at side 3 still line up and the inner
    # gap keeps its proportion.
    private def spot(pixel : Pixel, slot : Slot, side : Int32,
                     pitch : Float64, y_offset : Float64) : {Float64, Float64}
      stencil = @config.stencil
      sub = pitch / side
      {
        stencil.gap + pixel[0] * pitch + slot[1] * sub,
        stencil.gap + pixel[1] * pitch + slot[0] * sub + y_offset,
      }
    end

    private def size_for(login : String) : Float64
      @sizes[login]? || @config.stencil.pixel_size.to_f
    end

    private def ghost_paint : String
      mode.auto? ? %(class="mural-ghost") : %(fill="#{SVG.escape(palette.label_color)}")
    end
  end
end
