module ContributorMural
  class RasterError < Exception
  end

  # Seam for SVG -> PNG conversion so specs can inject a fake.
  abstract class Rasterizer
    abstract def rasterize(svg : String, scale : Float64) : Bytes
  end

  # Shells out to rsvg-convert (librsvg) — present in the action image, and
  # `brew install librsvg` / `apk add rsvg-convert` locally.
  class RsvgRasterizer < Rasterizer
    def initialize(@binary : String = "rsvg-convert")
    end

    def rasterize(svg : String, scale : Float64) : Bytes
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(@binary, ["--format", "png", "--zoom", scale.to_s],
        input: IO::Memory.new(svg), output: output, error: error)
      unless status.success?
        detail = error.to_s.strip.presence || "exit #{status.exit_code}"
        raise RasterError.new("rsvg-convert failed: #{detail}")
      end
      output.to_slice
    rescue ex : IO::Error
      raise RasterError.new("PNG output requires `rsvg-convert` (librsvg) on PATH — #{ex.message}")
    end
  end
end
