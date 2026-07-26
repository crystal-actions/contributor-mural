class FakeRasterizer < ContributorMural::Rasterizer
  getter calls = [] of {String, Float64}

  def rasterize(svg : String, scale : Float64) : Bytes
    calls << {svg, scale}
    "FAKEPNG@#{scale}".to_slice
  end
end
