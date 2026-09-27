module ContributorMural::Renderers
  # A picture drawn on a lattice of pixels, one avatar per lit pixel: what
  # stencil does with a word and silhouette does with an image. Each subclass
  # says which pixels are lit and in what order they fill; everything about
  # seating people on them lives here. Every pixel still waiting for someone
  # shows a faint dot, so the picture is legible from the first contributor and
  # finishes itself as more arrive.
  #
  # People are handed out one per pixel in fill order before any pixel gets a
  # second, and a pixel holding several splits into its own small grid. That
  # ordering is what keeps the picture from ever looking emptier after someone
  # joins — the failure mode of resizing every pixel at once.
  abstract class PixelLattice < Renderer
    GHOST_OPACITY = 0.38
    # Dot diameter as a share of its slot. A full-size disc reads as a wall of
    # broken images, but too small a dot stops joining up into strokes and the
    # picture becomes unreadable — which is the whole job the ghosts are here for.
    GHOST_RATIO = 0.62

    alias Pixel = {Int32, Int32}
    alias Slot = {Int32, Int32}

    @sizes = {} of String => Float64
    @slot_orders = {} of Int32 => Array(Slot)
    @layout : {Array(Pixel), Int32, Int32}?

    # {lit pixels in fill order, columns, rows}, with pixels as {column, row}.
    # The order is the contract: it is the order the picture is written in.
    protected abstract def build_layout : {Array(Pixel), Int32, Int32}

    protected abstract def pixel_size : Int32
    protected abstract def gap : Int32
    protected abstract def shape : Shape
    protected abstract def ghosts? : Bool
    protected abstract def clip_id : String

    # Sections draw the same picture independently, so size each person
    # against each section they are drawn in — bucketed by `sections`, the way
    # `Resolver.grouped` fills them, so someone who is also in a small section
    # is not fetched for the crowded one alone. Where their seats differ, the
    # fetch follows the largest, since a face drawn smaller than it was fetched
    # is only wasted bytes and one drawn larger is blurred.
    def prepare(users : Array(ResolvedUser)) : Nil
      pixels, _columns, _rows = layout
      capacity = pixels.size
      return if capacity.zero?

      sections = {} of String? => Array(ResolvedUser)
      users.each { |user| user.sections.each { |section| (sections[section] ||= [] of ResolvedUser) << user } }
      sections.each_value do |members|
        seats(members.size, capacity).each_with_index do |(pixel, _pass), index|
          size = pixel_size / grid_of(members_at(pixel, members.size, capacity)).to_f
          login = members[index].login
          @sizes[login] = Math.max(@sizes[login]? || 0.0, size)
        end
      end
    end

    def fetch_size(user : ResolvedUser) : Int32
      (size_for(user.login) * 2).ceil.to_i
    end

    protected def title_inset : Float64
      gap.to_f
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, clip_id, shape)
    end

    protected def style_rules(palette : Palette) : String
      ghosts? ? ".mural-ghost{fill:#{palette.label_color}}" : ""
    end

    # Depends only on the picture and the pixel geometry, so a section of six
    # and a section of six hundred come out exactly the same size.
    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      _pixels, columns, rows = layout
      return {16.0, 16.0} if columns.zero?

      pitch = (pixel_size + gap).to_f
      {gap + columns * pitch, gap + rows * pitch}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      pixels, _columns, _rows = layout
      return if pixels.empty? || users.empty?

      capacity = pixels.size
      pitch = (pixel_size + gap).to_f
      draw_ghosts(io, pixels, users.size, pitch, y_offset) if ghosts?
      clipped = !shape.square?
      assignments = seats(users.size, capacity)

      users.each_with_index do |user, index|
        seat, pass = assignments[index]
        side = grid_of(members_at(seat, users.size, capacity))
        size = pixel_size / side.to_f
        x, y = spot(pixels[seat], slot_order(side)[pass], side, pitch, y_offset)

        linked(io, user) { avatar(io, user, x, y, size, size, clipped ? clip_id : nil) }
      end
    end

    # One dot per empty sub-slot, as a single group so the fill is inherited
    # rather than repeated a few hundred times.
    private def draw_ghosts(io : String::Builder, pixels : Array(Pixel), count : Int32,
                            pitch : Float64, y_offset : Float64) : Nil
      capacity = pixels.size
      slots = pixels.size.times.sum { |index| grid_of(members_at(index, count, capacity)) ** 2 }
      return if slots <= count

      io << %(  <g #{ghost_paint} opacity="#{SVG.num(GHOST_OPACITY)}">\n)
      pixels.each_with_index do |pixel, index|
        members = members_at(index, count, capacity)
        side = grid_of(members)
        size = pixel_size / side.to_f
        radius = Math.max(size * GHOST_RATIO / 2, 1.0)
        order = slot_order(side)
        (members...order.size).each do |position|
          x, y = spot(pixel, order[position], side, pitch, y_offset)
          io << %(    <circle cx="#{SVG.num(x + size / 2)}" cy="#{SVG.num(y + size / 2)}" r="#{SVG.num(radius)}"/>\n)
        end
      end
      io << "  </g>\n"
    end

    protected def layout : {Array(Pixel), Int32, Int32}
      @layout ||= build_layout
    end

    # Pixel `index` holds this many people. Quotas differ by at most one, so
    # every pixel is served before any is served twice.
    #
    # Below capacity the served pixels are a contiguous prefix, which is what
    # writes the picture in its fill order. Above it the surplus is spread
    # evenly instead: clumping the denser pixels would leave the front of the
    # picture fine-grained and the back coarse, which reads as a broken render
    # rather than as texture.
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
    # half-full pixel's faces in its top row and band the whole picture.
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
      sub = pitch / side
      {
        gap + pixel[0] * pitch + slot[1] * sub,
        gap + pixel[1] * pitch + slot[0] * sub + y_offset,
      }
    end

    private def size_for(login : String) : Float64
      @sizes[login]? || pixel_size.to_f
    end

    private def ghost_paint : String
      mode.auto? ? %(class="mural-ghost") : %(fill="#{SVG.escape(palette.label_color)}")
    end
  end
end
