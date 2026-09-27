require "file_utils"
require "./spec_helper"

# These run the real rsvg-convert, like spec/rasterizer_spec.cr: tracing *is*
# librsvg plus a PNG decoder, and a fake would test neither. The fixtures are
# one L shape saved every way it can arrive — vector, transparent PNG, and
# JPEG both ways round (on a page with a margin, as a real one has) — whose
# edges fall on cell boundaries at the resolutions used here, so the expected
# masks are exact.
private ELL = [{0, 0}, {0, 1}, {1, 1}, {2, 1}]

private def fixtures : String
  SpecHelper.fixture("silhouette")
end

private def silhouette(image : String, resolution : Int32 = 3, ink : String = "auto",
                       threshold : Float64 = 0.5) : ContributorMural::SilhouetteConfig
  ContributorMural::SilhouetteConfig.from_yaml(
    "image: #{image}\nresolution: #{resolution}\nink: #{ink}\nthreshold: #{threshold}")
end

private def trace(image : String, **options) : ContributorMural::SilhouetteMask
  ContributorMural::SilhouetteTracer.load(fixtures, silhouette(image, **options),
    ContributorMural::RsvgRasterizer.new)
end

private def trace_in(workspace : String, image : String) : ContributorMural::SilhouetteMask
  ContributorMural::SilhouetteTracer.load(workspace, silhouette(image), ContributorMural::RsvgRasterizer.new)
end

private def in_scratch(& : String ->)
  workspace = File.tempname("mural_silhouette")
  Dir.mkdir_p(workspace)
  yield workspace
ensure
  FileUtils.rm_rf(workspace) if workspace
end

private def trace_error(workspace : String, image : String) : String
  ContributorMural::SilhouetteTracer.load(workspace, silhouette(image), ContributorMural::RsvgRasterizer.new)
  ""
rescue ex : ContributorMural::ConfigError
  ex.message || ""
end

describe ContributorMural::SilhouetteTracer do
  {"ell.svg", "ell.png", "ell.jpg", "ell-negative.jpg"}.each do |image|
    it "traces the same shape out of #{image}" do
      mask = trace(image)
      mask.columns.should eq(3)
      mask.rows.should eq(2)
      mask.cells.sort.should eq(ELL.sort)
    end
  end

  it "puts `resolution` cells along the longer side and follows the aspect on the other" do
    mask = trace("ell.svg", resolution: 6)
    mask.columns.should eq(6)
    mask.rows.should eq(4)
    # Two thirds of a 3×2 L, at twice the density.
    mask.cells.size.should eq(16)
  end

  it "takes the ink the way it is told, whichever way round the image is" do
    trace("ell.jpg", ink: "dark").cells.sort.should eq(ELL.sort)
    trace("ell-negative.jpg", ink: "light").cells.sort.should eq(ELL.sort)
    # Told the wrong way round, the white margin becomes the shape instead.
    trace("ell.jpg", ink: "light").cells.sort.should_not eq(ELL.sort)
  end

  it "takes the whole opaque image under `alpha`" do
    # The JPEGs are the L on a 40 × 30 unit page: 4 × 3 cells, every one opaque.
    mask = trace("ell.jpg", ink: "alpha", resolution: 4)
    {mask.columns, mask.rows}.should eq({4, 3})
    mask.cells.size.should eq(12)
  end

  it "keeps only cells that are at least `threshold` ink" do
    # At resolution 5 a cell is 6 units, so the cells that straddle the L's
    # inner edges are two-thirds and one-half ink: in at 0.2, out at 0.8.
    trace("ell.svg", resolution: 5, threshold: 0.2).cells.size.should eq(12)
    trace("ell.svg", resolution: 5, threshold: 0.8).cells.size.should eq(8)
  end

  it "traces a cut-out by its alpha even when what it cuts out is a solid rectangle" do
    # A white square with a black centre on a transparent PNG: the whole
    # square is the shape, not just the dark middle of it.
    mask = trace("square-on-clear.png")
    {mask.columns, mask.rows}.should eq({3, 3})
    mask.cells.size.should eq(9)
  end

  it "traces a pale logo, reading its strongest colour as full ink" do
    # Orange on white is only about 0.4 dark.
    trace("ell-orange.jpg").cells.sort.should eq(ELL.sort)
  end

  it "keeps the aspect ratio of an SVG that has a size but no viewBox" do
    in_scratch do |workspace|
      File.write(File.join(workspace, "bare.svg"),
        %(<svg xmlns="http://www.w3.org/2000/svg" width="30px" height="20"><path d="M0 0h10v10h20v10H0z"/></svg>))
      mask = trace_in(workspace, "bare.svg")
      {mask.columns, mask.rows}.should eq({3, 2})
      mask.cells.sort.should eq(ELL.sort)
    end
  end

  it "finds an SVG behind a long prolog" do
    in_scratch do |workspace|
      svg = File.read(File.join(fixtures, "ell.svg"))
      File.write(File.join(workspace, "licensed.svg"), %(<?xml version="1.0"?>\n<!-- #{"licence text " * 600} -->\n#{svg}))
      trace_in(workspace, "licensed.svg").cells.sort.should eq(ELL.sort)
    end
  end

  describe "refusing an image" do
    it "names a file that is not there" do
      trace_error(fixtures, "nope.png").should contain("silhouette `image` not found: nope.png")
    end

    it "names a file that is not an image" do
      workspace = File.tempname("mural_silhouette")
      Dir.mkdir_p(workspace)
      File.write(File.join(workspace, "notes.txt"), "just some text")
      trace_error(workspace, "notes.txt").should contain("is not a PNG, JPEG, GIF, WebP, or SVG")
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end

    it "says so when nothing in the image counts as ink" do
      workspace = File.tempname("mural_silhouette")
      Dir.mkdir_p(workspace)
      File.write(File.join(workspace, "empty.svg"), %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>))
      trace_error(workspace, "empty.svg").should contain("came out blank")
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end

    it "stops at the size librsvg can still take as a data URI" do
      in_scratch do |workspace|
        File.write(File.join(workspace, "huge.png"), Bytes.new(ContributorMural::SilhouetteTracer::MAX_BYTES + 1))
        trace_error(workspace, "huge.png").should contain("is larger than 7 MB")
      end
    end

    it "names the ink `auto` settled on when nothing matched it" do
      in_scratch do |workspace|
        File.write(File.join(workspace, "white.svg"),
          %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#fff"/></svg>))
        trace_error(workspace, "white.svg").should contain("(read as `dark`)")
      end
    end

    it "will not follow a symlink out of the repository" do
      workspace = File.tempname("mural_silhouette")
      Dir.mkdir_p(workspace)
      File.symlink(File.join(fixtures, "ell.svg"), File.join(workspace, "logo.svg"))
      trace_error(workspace, "logo.svg").should contain("must stay inside the repository")
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end
  end

  describe ".decode" do
    it "refuses bytes that are not a PNG" do
      expect_raises(ContributorMural::RasterError, /not a PNG/) do
        ContributorMural::SilhouetteTracer.decode("GIF89a and then some".to_slice)
      end
    end

    it "refuses a PNG whose image data is not a zlib stream" do
      png = ContributorMural::RsvgRasterizer.new.rasterize(File.read(File.join(fixtures, "ell.svg")), 1.0)
      idat = (0..png.size - 4).find! { |index| png[index, 4] == "IDAT".to_slice }
      corrupt = png.dup
      corrupt[idat + 4] = 0xFF_u8 # the zlib header's first byte
      expect_raises(ContributorMural::RasterError, /could not be read/) do
        ContributorMural::SilhouetteTracer.decode(corrupt)
      end
    end

    it "refuses a PNG cut short" do
      png = ContributorMural::RsvgRasterizer.new.rasterize(File.read(File.join(fixtures, "ell.svg")), 1.0)
      expect_raises(ContributorMural::RasterError) do
        ContributorMural::SilhouetteTracer.decode(png[0, png.size // 2])
      end
    end
  end
end
