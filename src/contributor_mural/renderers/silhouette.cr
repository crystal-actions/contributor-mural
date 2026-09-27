module ContributorMural::Renderers
  # The wall as a picture: avatars fill the outline of an image — a logo, a
  # mascot, a heart — traced onto a lattice of pixels by `SilhouetteTracer`.
  # Stencil with a picture where the word was; the seating and the ghost dots
  # are `PixelLattice`'s.
  #
  # The picture fills from its middle outward, so the heaviest contributor sits
  # at the heart of it and every newcomer lands on the rim of the crowd so far.
  # Reading order, stencil's choice, suits letters and not pictures: a logo
  # filled top-down spends its first dozen people on an edge, and looks cropped
  # rather than unfinished.
  class Silhouette < PixelLattice
    CLIP_ID = "silhouette-clip"

    def initialize(config : Config, mode : ThemeMode?, @mask : SilhouetteMask)
      super(config, mode)
    end

    protected def pixel_size : Int32
      @config.silhouette.pixel_size
    end

    protected def gap : Int32
      @config.silhouette.gap
    end

    protected def shape : Shape
      @config.silhouette.shape
    end

    protected def ghosts? : Bool
      @config.silhouette.ghosts?
    end

    protected def clip_id : String
      CLIP_ID
    end

    # Nearest the shape's centroid first, ties in reading order. The distance
    # is kept in integers — each coordinate scaled by the cell count, cell
    # centres doubled — because this order is golden-file contract, and a tie
    # decided by the last bit of a float is one that can flip.
    protected def build_layout : {Array(Pixel), Int32, Int32}
      cells = @mask.cells
      return {[] of Pixel, 0, 0} if cells.empty?

      count = cells.size.to_i64
      sum_x = cells.sum(0_i64) { |(column, _row)| 2_i64 * column + 1 }
      sum_y = cells.sum(0_i64) { |(_column, row)| 2_i64 * row + 1 }
      ordered = cells.sort_by do |(column, row)|
        dx = count * (2 * column + 1) - sum_x
        dy = count * (2 * row + 1) - sum_y
        {dx * dx + dy * dy, row, column}
      end
      {ordered, @mask.columns, @mask.rows}
    end
  end
end
