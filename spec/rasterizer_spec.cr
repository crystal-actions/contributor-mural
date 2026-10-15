require "./spec_helper"

private TINY_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8" viewBox="0 0 8 8"><rect width="8" height="8" fill="#ff0000"/></svg>)

describe ContributorMural::RsvgRasterizer do
  it "produces a PNG from an SVG" do
    bytes = ContributorMural::RsvgRasterizer.new.rasterize(TINY_SVG, 2.0)
    bytes[0, 8].should eq(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  end

  it "fails with a helpful message when the binary is missing" do
    rasterizer = ContributorMural::RsvgRasterizer.new(binary: "rsvg-convert-nope")
    expect_raises(ContributorMural::RasterError, /rsvg-convert/) do
      rasterizer.rasterize(TINY_SVG, 1.0)
    end
  end

  it "reports a rasterizer killed by a signal as a RasterError" do
    script = File.tempname("rsvg-killed", ".sh")
    File.write(script, "#!/bin/sh\nkill -9 $$\n")
    File.chmod(script, 0o755)
    expect_raises(ContributorMural::RasterError, /killed by KILL/) do
      ContributorMural::RsvgRasterizer.new(binary: script).rasterize(TINY_SVG, 1.0)
    end
  ensure
    File.delete?(script) if script
  end
end
