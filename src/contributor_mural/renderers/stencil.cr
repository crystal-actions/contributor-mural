module ContributorMural::Renderers
  # The wall as a word: avatars fill the lit pixels of `text` set in a built-in
  # 5x7 face. The seating — one person per pixel before anyone shares, and the
  # ghost dots on the pixels still waiting — is `PixelLattice`'s; this only
  # sets the word.
  class Stencil < PixelLattice
    CLIP_ID = "stencil-clip"

    protected def pixel_size : Int32
      @config.stencil.pixel_size
    end

    protected def gap : Int32
      @config.stencil.gap
    end

    protected def shape : Shape
      @config.stencil.shape
    end

    protected def ghosts? : Bool
      @config.stencil.ghosts?
    end

    protected def clip_id : String
      CLIP_ID
    end

    # Glyph by glyph left to right, and row-major inside a glyph: capitals are
    # read through their horizontal features, so a half-filled letter scanned
    # top-down still reads as itself.
    protected def build_layout : {Array(Pixel), Int32, Int32}
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
  end
end
