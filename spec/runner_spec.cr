require "file_utils"
require "./spec_helper"
require "./support/fake_avatar_source"
require "./support/fake_github_source"
require "./support/fake_rasterizer"

private def run_in_tmp(config_yaml : String, source = FakeAvatarSource.new,
                       github_source : ContributorMural::GitHubSource? = nil,
                       rasterizer : ContributorMural::Rasterizer? = nil,
                       & : Int32, String, String ->)
  workspace = File.tempname("mural_ws")
  Dir.mkdir_p(workspace)
  output_file = File.tempname("gh_output")
  annotations = IO::Memory.new
  ContributorMural::Annotations.io = annotations
  ENV["GITHUB_OUTPUT"] = output_file
  begin
    config = ContributorMural::Config.parse(config_yaml)
    config.validate!
    exit_code = ContributorMural::Runner.new(config, source, workspace, github_source, nil, rasterizer).run
    outputs = File.exists?(output_file) ? File.read(output_file) : ""
    yield exit_code, outputs, workspace
  ensure
    ContributorMural::Annotations.io = STDOUT
    ENV.delete("GITHUB_OUTPUT")
    File.delete?(output_file)
    FileUtils.rm_rf(workspace)
  end
end

describe ContributorMural::Runner do
  it "writes the SVG and step outputs" do
    yaml = <<-YAML
      output: art/wall.svg
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      svg = File.read(File.join(workspace, "art/wall.svg"))
      svg.should contain("data:image/png;base64,")
      outputs.should contain("paths=art/wall.svg")
      outputs.should contain("user_count=2")
    end
  end

  # A voronoi block can land on a fractional width, and an <img> width
  # attribute has to be a whole number, so the output is the SVG's own size
  # rounded up — never down, which would crop it.
  it "reports the rendered size, rounded up from the SVG root element" do
    yaml = <<-YAML
      style: voronoi
      output: wall.svg
      users:
        - login: alpha
        - login: bravo
        - login: charlie
      YAML

    run_in_tmp(yaml) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      svg = File.read(File.join(workspace, "wall.svg"))
      root = svg.lines.first
      svg_width = root.match!(/ width="([\d.]+)"/)[1].to_f
      svg_height = root.match!(/ height="([\d.]+)"/)[1].to_f

      outputs.should contain("width=#{svg_width.ceil.to_i}")
      outputs.should contain("height=#{svg_height.ceil.to_i}")
    end
  end

  it "reports a PNG's own dimensions rather than the SVG's scaled" do
    yaml = <<-YAML
      output: wall.png
      png:
        scale: 2
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml, rasterizer: FakeRasterizer.new({321, 123})) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      outputs.should contain("width=321")
      outputs.should contain("height=123")
    end
  end

  # A rasterizer that hands back something unparseable should still leave the
  # embed side with a usable number rather than no output at all.
  it "falls back to the scaled SVG size when the PNG cannot be read" do
    yaml = <<-YAML
      output: wall.png
      png:
        scale: 2
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml, rasterizer: FakeRasterizer.new) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      width = outputs.lines.find!(&.starts_with?("width=")).split('=', 2).last.to_i
      width.should be > 0
    end
  end

  it "reports the first target when several files are rendered" do
    yaml = <<-YAML
      outputs:
        - path: small.svg
          style: grid
        - path: big.svg
          style: orbit
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      grid_width = File.read(File.join(workspace, "small.svg")).lines.first.match!(/ width="([\d.]+)"/)[1].to_f
      orbit_width = File.read(File.join(workspace, "big.svg")).lines.first.match!(/ width="([\d.]+)"/)[1].to_f
      grid_width.should_not eq(orbit_width) # otherwise this proves nothing

      outputs.should contain("width=#{grid_width.ceil.to_i}")
    end
  end

  it "renders multiple outputs reusing fetches" do
    yaml = <<-YAML
      outputs:
        - path: one.svg
        - path: two.svg
      users:
        - login: alpha
      YAML

    source = FakeAvatarSource.new
    run_in_tmp(yaml, source) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      File.exists?(File.join(workspace, "one.svg")).should be_true
      File.exists?(File.join(workspace, "two.svg")).should be_true
      source.fetch_count.should eq(1)
      outputs.should contain("paths=one.svg,two.svg")
    end
  end

  it "warns and continues when an avatar is missing" do
    yaml = <<-YAML
      users:
        - login: alpha
        - login: gone
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["gone"])) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      ContributorMural::Annotations.io.to_s.should contain("::warning::skipped gone")
      outputs.should contain("user_count=1")
    end
  end

  # Silently dropping the option reads as "scale is broken" rather than "this
  # style has no room for it", and nothing in the SVG can say which happened.
  it "warns when a style cannot honour a per-user scale" do
    yaml = <<-YAML
      outputs:
        - path: wall.svg
          style: grid
        - path: bloom.svg
          style: spiral
      users:
        - login: alpha
          scale: 1.6
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      # Named per style, and only the one that dropped it: the spiral output
      # in the same config renders the emphasis fine.
      ContributorMural::Annotations.io.to_s
        .should contain("::warning::per-user `scale` is ignored by grid —")
    end
  end

  it "stays quiet about scale when every style honours it" do
    yaml = <<-YAML
      style: mosaic
      users:
        - login: alpha
          scale: 1.6
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      ContributorMural::Annotations.io.to_s.should_not contain("scale")
    end
  end

  it "merges contributors from the API source" do
    yaml = <<-YAML
      contributors:
        repo: hahwul/contributor-mural
      users:
        - login: hahwul
          weight: 99
      YAML

    api_users = [
      ContributorMural::ResolvedUser.new("contributor", weight: 5),
      ContributorMural::ResolvedUser.new("hahwul", weight: 1),
    ]
    github_source = FakeGitHubSource.new(api_users)

    run_in_tmp(yaml, github_source: github_source) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      github_source.requested_repos.should eq(["hahwul/contributor-mural"])
      outputs.should contain("user_count=2")
      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      svg.should contain(%(href="https://github.com/contributor"))
    end
  end

  it "rasterizes .png outputs with a static light palette" do
    yaml = <<-YAML
      outputs:
        - path: wall.svg
        - path: wall.png
        - path: wall-dark.png
          mode: dark
      users:
        - login: alpha
      YAML

    rasterizer = FakeRasterizer.new
    run_in_tmp(yaml, rasterizer: rasterizer) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      String.new(File.read(File.join(workspace, "wall.png")).to_slice).should eq("FAKEPNG@2.0")
      rasterizer.calls.size.should eq(2)
      light_svg = rasterizer.calls[0][0]
      light_svg.should_not contain("<style>")
      light_svg.should contain(%(fill="#57606a"))
      dark_svg = rasterizer.calls[1][0]
      dark_svg.should contain(%(fill="#8b949e"))
      File.read(File.join(workspace, "wall.svg")).should contain("<style>")
      outputs.should contain("paths=wall.svg,wall.png,wall-dark.png")
    end
  end

  it "fails cleanly when a png is requested without a rasterizer" do
    yaml = <<-YAML
      output: wall.png
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(1)
      ContributorMural::Annotations.io.to_s.should contain("no rasterizer")
    end
  end

  it "combines members, stargazers, and sponsors into their groups" do
    yaml = <<-YAML
      groups: [Team, Stars, Sponsors]
      users:
        - login: hahwul
      members:
        org: crystal-actions
        group: Team
      stargazers:
        repo: crystal-actions/contributor-mural
        group: Stars
      sponsors:
        login: hahwul
        group: Sponsors
      YAML

    github_source = FakeGitHubSource.new(
      members: [ContributorMural::ResolvedUser.new("teammate", group: "Team")],
      stargazers: [ContributorMural::ResolvedUser.new("fan", group: "Stars")],
      sponsors: [ContributorMural::ResolvedUser.new("patron", weight: 25, group: "Sponsors")],
    )

    run_in_tmp(yaml, github_source: github_source) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      github_source.requested_orgs.should eq(["crystal-actions"])
      github_source.requested_star_repos.should eq(["crystal-actions/contributor-mural"])
      github_source.requested_sponsor_logins.should eq(["hahwul"])
      outputs.should contain("user_count=4")
      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      svg.should contain(">Team</text>")
      svg.should contain(">Stars</text>")
      svg.should contain(">Sponsors</text>")
    end
  end

  it "merges the sources in configuration order, not completion order" do
    # The four sources are fetched together now, so the order they come back in
    # is no longer the order they finish in. It still has to be the order the
    # config lists them, because that is what decides who wins a duplicate and
    # who lands where in the mural.
    yaml = <<-YAML
      sort: none
      contributors:
        repo: o/r
      members:
        org: acme
      stargazers:
        repo: o/r
      sponsors:
        login: acme
      YAML

    github_source = FakeGitHubSource.new(
      contributors: [ContributorMural::ResolvedUser.new("from_contributors")],
      members: [ContributorMural::ResolvedUser.new("from_members")],
      stargazers: [ContributorMural::ResolvedUser.new("from_stargazers")],
      sponsors: [ContributorMural::ResolvedUser.new("from_sponsors")],
    )

    run_in_tmp(yaml, github_source: github_source) do |exit_code, _outputs, workspace|
      exit_code.should eq(0)
      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      logins = svg.scan(/href="https:\/\/github\.com\/(from_\w+)"/).map(&.[1])
      logins.should eq(["from_contributors", "from_members", "from_stargazers", "from_sponsors"])
    end
  end

  it "reports a missing repo before any source is contacted" do
    # The config errors are settled on the calling fiber, ahead of the fan-out,
    # so which one is reported cannot depend on request timing.
    yaml = <<-YAML
      stargazers:
        max: 10
      members:
        org: acme
      YAML

    github_source = FakeGitHubSource.new(
      members: [ContributorMural::ResolvedUser.new("teammate")],
    )
    previous = ENV["GITHUB_REPOSITORY"]?
    ENV.delete("GITHUB_REPOSITORY")
    begin
      run_in_tmp(yaml, github_source: github_source) do |exit_code, _outputs, _workspace|
        exit_code.should eq(1)
        github_source.requested_orgs.should be_empty
      end
    ensure
      ENV["GITHUB_REPOSITORY"] = previous if previous
    end
  end

  it "always reports `changed`, including when committing is off" do
    yaml = <<-YAML
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      outputs.should contain("changed=false")
      outputs.should contain("paths=CONTRIBUTOR_MURAL.svg")
    end
  end

  it "refuses to overwrite an existing wall when every source is empty" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: alpha
      exclude: [alpha]
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, workspace|
      File.write(File.join(workspace, "wall.svg"), "PRECIOUS")
      exit_code.should eq(1)
      File.read(File.join(workspace, "wall.svg")).should eq("PRECIOUS")
      ContributorMural::Annotations.io.to_s.should contain("no users to render")
    end
  end

  it "writes nothing when a later output cannot be produced" do
    yaml = <<-YAML
      outputs:
        - path: first.svg
        - path: second.png
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, workspace|
      exit_code.should eq(1)
      File.exists?(File.join(workspace, "first.svg")).should be_false
      ContributorMural::Annotations.io.to_s.should contain("no rasterizer is available")
    end
  end

  it "fails cleanly when contributors are requested without API access" do
    yaml = <<-YAML
      contributors:
        repo: hahwul/contributor-mural
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(1)
      ContributorMural::Annotations.io.to_s.should contain("::error::the configured sources need GitHub API access")
    end
  end

  it "fails when fail_on_missing is set" do
    yaml = <<-YAML
      fail_on_missing: true
      users:
        - login: gone
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["gone"])) do |exit_code, _outputs, _workspace|
      exit_code.should eq(1)
      ContributorMural::Annotations.io.to_s.should contain("::error::gone")
    end
  end
end
