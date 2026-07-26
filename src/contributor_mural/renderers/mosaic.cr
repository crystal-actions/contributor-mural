module ContributorMural::Renderers
  # Weight-tiered collage: heavier users occupy larger squares. Tier spans
  # come from weight rank across the whole render (top fraction gets
  # tiers[0], and so on); each section is packed first-fit onto its own unit
  # grid in list order, so placement is deterministic and follows the
  # configured sort.
  class Mosaic < Renderer
    CLIP_ID = "cell-clip"

    @spans = {} of String => Int32

    def prepare(users : Array(ResolvedUser)) : Nil
      tiers = @config.mosaic.tiers
      ranked = users.sort_by { |user| {-user.weight, user.login.downcase} }
      ranked.each_with_index do |user, index|
        tier_index = index * tiers.size // ranked.size
        @spans[user.login] = tiers[tier_index]
      end
    end

    def fetch_size(user : ResolvedUser) : Int32
      span_for(user.login) * @config.mosaic.base_cell * 2
    end

    protected def title_inset : Float64
      @config.mosaic.gap.to_f
    end

    protected def defs(io : String::Builder) : Nil
      io << %(  <defs><clipPath id="#{CLIP_ID}" clipPathUnits="objectBoundingBox"><rect width="1" height="1" rx="0.08"/></clipPath></defs>\n)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      mosaic = @config.mosaic
      unit = mosaic.base_cell + mosaic.gap
      columns = column_count(users)
      spans = users.map { |user| span_for(user.login) }
      cells = pack(spans, columns)
      rows_used = cells.each_with_index.max_of? { |(cell, index)| cell[0] + spans[index] } || 0
      # Shrink to the columns the packer actually filled so a short list does
      # not render onto a full-width canvas.
      cols_used = cells.each_with_index.max_of? { |(cell, index)| cell[1] + spans[index] } || 0
      {(mosaic.gap + cols_used * unit).to_f, (mosaic.gap + rows_used * unit).to_f}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      mosaic = @config.mosaic
      unit = mosaic.base_cell + mosaic.gap
      columns = column_count(users)
      spans = users.map { |user| span_for(user.login) }
      cells = pack(spans, columns)

      users.each_with_index do |user, index|
        row, col = cells[index]
        span = spans[index]
        x = mosaic.gap + col * unit
        y = mosaic.gap + row * unit + y_offset
        size = span * mosaic.base_cell + (span - 1) * mosaic.gap

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{size}" height="#{size}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{CLIP_ID})"/>\n)
        io << "  </a>\n"
      end
    end

    private def column_count(users : Array(EmbeddedUser)) : Int32
      mosaic = @config.mosaic
      Math.max((mosaic.width + mosaic.gap) // (mosaic.base_cell + mosaic.gap), max_span(users))
    end

    private def span_for(login : String) : Int32
      @spans[login]? || 1
    end

    private def max_span(users : Array(EmbeddedUser)) : Int32
      users.max_of? { |user| span_for(user.login) } || 1
    end

    # First-fit packing on a growing occupancy grid: for each item, scan
    # top-to-bottom, left-to-right for the first free span x span area.
    private def pack(spans : Array(Int32), columns : Int32) : Array({Int32, Int32})
      occupied = [] of Array(Bool)
      spans.map do |span|
        row = 0
        loop do
          if col = fit_at(occupied, row, columns, span)
            mark(occupied, row, col, span, columns)
            break {row, col}
          end
          row += 1
        end
      end
    end

    private def fit_at(occupied : Array(Array(Bool)), row : Int32, columns : Int32, span : Int32) : Int32?
      (0..columns - span).each do |col|
        return col if area_free?(occupied, row, col, span)
      end
      nil
    end

    private def area_free?(occupied : Array(Array(Bool)), row : Int32, col : Int32, span : Int32) : Bool
      span.times do |row_offset|
        cells = occupied[row + row_offset]?
        next unless cells
        span.times do |col_offset|
          return false if cells[col + col_offset]
        end
      end
      true
    end

    private def mark(occupied : Array(Array(Bool)), row : Int32, col : Int32, span : Int32, columns : Int32) : Nil
      while occupied.size < row + span
        occupied << Array(Bool).new(columns, false)
      end
      span.times do |row_offset|
        span.times do |col_offset|
          occupied[row + row_offset][col + col_offset] = true
        end
      end
    end
  end
end
