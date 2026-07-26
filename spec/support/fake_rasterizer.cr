class FakeRasterizer < ContributorMural::Rasterizer
  getter calls = [] of {String, Float64}

  # With `png_size` set, the fake emits a byte string that opens like a real
  # PNG (signature + IHDR), so specs can exercise reading the dimensions back
  # off the rasterized file. Left nil, the output is a plain marker.
  def initialize(@png_size : {Int32, Int32}? = nil)
  end

  def rasterize(svg : String, scale : Float64) : Bytes
    calls << {svg, scale}
    if size = @png_size
      header(size[0], size[1])
    else
      "FAKEPNG@#{scale}".to_slice
    end
  end

  private def header(width : Int32, height : Int32) : Bytes
    io = IO::Memory.new
    io.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    io.write_bytes(13_u32, IO::ByteFormat::BigEndian)
    io << "IHDR"
    io.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    io.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    io.to_slice
  end
end
