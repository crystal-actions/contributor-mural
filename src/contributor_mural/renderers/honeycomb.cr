module ContributorMural::Renderers
  # Hex-clipped avatars in offset rows, like a honeycomb wall.
  # Pointy-top hexagons: width = cell_size, height = cell_size * 2/√3,
  # odd rows shift half a cell right and hold one less item.
  class Honeycomb < Renderer
    CLIP_ID = "hex-clip"
    # Fractions of the bounding box for a pointy-top hexagon.
    CLIP_POINTS = "0.5,0 1,0.25 1,0.75 0.5,1 0,0.75 0,0.25"

    def fetch_size(user : ResolvedUser) : Int32
      @config.honeycomb.cell_size * 2
    end

    protected def title_inset : Float64
      @config.honeycomb.gap.to_f
    end

    protected def defs(io : String::Builder) : Nil
      io << %(  <defs><clipPath id="#{CLIP_ID}" clipPathUnits="objectBoundingBox"><polygon points="#{CLIP_POINTS}"/></clipPath></defs>\n)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      hc = @config.honeycomb
      cell_w = hc.cell_size.to_f
      cell_h = cell_w * 2 / Math.sqrt(3.0)
      gap = hc.gap.to_f
      pitch = 0.75 * cell_h + gap

      cells = positions(users.size, hc.columns)
      rows_used = cells.empty? ? 0 : cells.last[0] + 1
      # Only as wide as the widest row actually is: a 9-column setting with
      # two members should not leave seven columns of blank canvas.
      cols_used = cells.max_of? { |(row, col)| col + 1 + (row.odd? && hc.columns > 1 ? 1 : 0) } || 0
      cols_used = Math.min(cols_used, hc.columns)
      width = cols_used.zero? ? gap * 2 : gap + cols_used * (cell_w + gap)
      height = rows_used.zero? ? gap * 2 : gap + (rows_used - 1) * pitch + cell_h + gap
      {width, height}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      hc = @config.honeycomb
      cell_w = hc.cell_size.to_f
      cell_h = cell_w * 2 / Math.sqrt(3.0)
      gap = hc.gap.to_f
      pitch = 0.75 * cell_h + gap
      cells = positions(users.size, hc.columns)

      users.each_with_index do |user, index|
        row, col = cells[index]
        x = gap + col * (cell_w + gap)
        x += (cell_w + gap) / 2 if row.odd? && hc.columns > 1
        y = gap + row * pitch + y_offset

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(cell_w)}" height="#{SVG.num(cell_h)}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{CLIP_ID})"/>\n)
        io << "  </a>\n"
      end
    end

    # {row, col} for each index; odd rows hold one item less so their shifted
    # cells nest between the hexagons above.
    private def positions(count : Int32, columns : Int32) : Array({Int32, Int32})
      result = [] of {Int32, Int32}
      row = 0
      col = 0
      count.times do
        capacity = row.odd? ? Math.max(columns - 1, 1) : columns
        if col >= capacity
          row += 1
          col = 0
        end
        result << {row, col}
        col += 1
      end
      result
    end
  end
end
