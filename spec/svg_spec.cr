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

  {"grid", "honeycomb", "mosaic", "spiral", "orbit", "voronoi", "stencil"}.each do |style|
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
