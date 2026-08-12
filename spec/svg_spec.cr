require "xml"
require "file_utils"
require "./spec_helper"
require "./support/fake_avatar_source"

# Every name, role and section title reaches the document through `SVG.escape`,
# so that is the one place the file's well-formedness is decided. The end-to-end
# examples below are what keep that claim true: a style that ever emitted user
# text some other way would fail them, not the unit tests.
private HOSTILE_TEXT = "Bob <script>alert(1)</script> & \"quoted\" ']]>' \u{0001}\u{0000}bell 박하울 ♥ 😀"

private def render_hostile(style : String) : String
  quoted = HOSTILE_TEXT.inspect
  yaml = <<-YAML
    style: #{style}
    output: out.svg
    groups: [#{quoted}]
    users:
      - login: alpha
        name: #{quoted}
        role: #{quoted}
        group: #{quoted}
        weight: 5
      - login: bravo
        name: plain
        group: #{quoted}
        weight: 1
    YAML

  workspace = File.tempname("mural_svg")
  Dir.mkdir_p(workspace)
  annotations = IO::Memory.new
  ContributorMural::Annotations.io = annotations
  begin
    config = ContributorMural::Config.parse(yaml)
    config.validate!
    code = ContributorMural::Runner.new(config, FakeAvatarSource.new, workspace).run
    code.should eq(0), "#{style} did not render: #{annotations}"
    File.read(File.join(workspace, "out.svg"))
  ensure
    ContributorMural::Annotations.io = STDOUT
    FileUtils.rm_rf(workspace)
  end
end

describe ContributorMural::SVG do
  describe ".escape" do
    it "escapes the characters that would end an attribute or open a tag" do
      escaped = ContributorMural::SVG.escape(%(<a href="x">&'))
      escaped.should_not contain('<')
      escaped.should_not contain('>')
      escaped.should_not contain('"')
      XML.parse(%(<t a="#{escaped}">#{escaped}</t>)).errors.should be_nil
    end

    # XML allows three control characters and no parser will read a document
    # carrying any of the others. `HTML.escape` leaves all of them alone, since
    # in HTML they are legal — so a display name with one stray byte used to cost
    # the whole file rather than one label, with the run still exiting 0.
    it "drops the control characters XML cannot carry" do
      ContributorMural::SVG.escape("a\u{0001}b\u{0000}c\u{001F}d").should eq("abcd")
      ContributorMural::SVG.escape("a\u{FFFE}b\u{FFFF}c").should eq("abc")
    end

    it "keeps the whitespace XML does allow, and leaves ordinary text alone" do
      ContributorMural::SVG.escape("a\tb\nc\rd").should eq("a\tb\nc\rd")
      ContributorMural::SVG.escape("박하울 ♥ 😀").should eq("박하울 ♥ 😀")
    end
  end

  # Every coordinate in every style goes through `num`, so the golden files are
  # only stable while its formatting is.
  describe ".num" do
    it "drops the decimals a coordinate does not need" do
      ContributorMural::SVG.num(12.0).should eq("12")
      ContributorMural::SVG.num(12.5).should eq("12.5")
      ContributorMural::SVG.num(12.25).should eq("12.25")
      ContributorMural::SVG.num(0.0).should eq("0")
      ContributorMural::SVG.num(-1.5).should eq("-1.5")
    end

    it "rounds to two decimals" do
      ContributorMural::SVG.num(1.005).should eq("1")
      ContributorMural::SVG.num(0.999).should eq("1")
      ContributorMural::SVG.num(0.004).should eq("0")
    end

    # "-0" is a legal SVG number and a pointless diff: it is what a value
    # rounds to from either side of zero, so the same layout could serialise
    # two ways depending on floating-point noise.
    it "never emits a negative zero" do
      ContributorMural::SVG.num(-0.001).should eq("0")
      ContributorMural::SVG.num(-0.0).should eq("0")
    end

    it "passes integers through untouched" do
      ContributorMural::SVG.num(7).should eq("7")
      ContributorMural::SVG.num(0).should eq("0")
      ContributorMural::SVG.num(-3).should eq("-3")
    end
  end

  describe ".document" do
    it "wraps the body in a sized root element" do
      svg = ContributorMural::SVG.document(10, 20.5) { |io| io << "<g/>" }
      svg.should eq(<<-SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="20.5" viewBox="0 0 10 20.5">
        <g/></svg>\n
        SVG
      XML.parse(svg).errors.should be_nil
    end

    it "formats the dimensions the same way coordinates are formatted" do
      svg = ContributorMural::SVG.document(100.0, 50.250) { }
      svg.should contain(%(width="100" height="50.25"))
      svg.should contain(%(viewBox="0 0 100 50.25"))
    end
  end

  {"grid", "honeycomb", "mosaic", "spiral", "orbit", "voronoi", "stencil", "constellation", "skyline", "metro", "pebble"}.each do |style|
    it "writes well-formed XML for #{style} however a user is named" do
      svg = render_hostile(style)

      document = XML.parse(svg)
      document.errors.should be_nil, "#{style}: #{document.errors.try(&.map(&.to_s).join("; "))}"
      document.root.try(&.name).should eq("svg")
      # The name has to arrive as text, never as markup.
      document.xpath_nodes("//*[local-name()='script']").should be_empty
      svg.should_not contain("<script")
    end
  end
end
