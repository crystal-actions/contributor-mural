require "file_utils"
require "./spec_helper"
require "./support/fake_avatar_source"
require "./support/fake_github_source"
require "./support/fake_rasterizer"

private def run_in_tmp(config_yaml : String, source = FakeAvatarSource.new,
                       github_source : ContributorMural::GitHubSource? = nil,
                       rasterizer : ContributorMural::Rasterizer? = nil,
                       before : Proc(String, Nil)? = nil,
                       & : Int32, String, String ->)
  workspace = File.tempname("mural_ws")
  Dir.mkdir_p(workspace)
  before.try(&.call(workspace))
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

  # A person on two walls is still one person: one avatar fetched, one entry in
  # `user_count`, one copy of the bytes in the file. Only the drawing repeats.
  it "draws a two-section person twice from one fetch" do
    yaml = <<-YAML
      sort: none
      groups: [Contributors, Special Thanks]
      users:
        - login: alpha
          group: Contributors
          also_in: [Special Thanks]
        - login: bravo
          group: Special Thanks
      YAML

    source = FakeAvatarSource.new
    run_in_tmp(yaml, source) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      source.fetch_count.should eq(2)
      outputs.should contain("user_count=2")

      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      svg.scan(/data:image\/png;base64,/).size.should eq(2)
      svg.scan(%r{<a href="https://github.com/alpha"}).size.should eq(2)
      svg.should contain(">Contributors</text>")
      svg.should contain(">Special Thanks</text>")
    end
  end

  # The two things a curated entry says on the gori wall that motivated both of
  # these: a section it also belongs to, and a role it inherits from the source
  # rather than repeating. The source role has to reach the person through
  # `from_entry`, and then travel with them into every section they appear in.
  it "carries a source role into every section a person is filed under" do
    yaml = <<-YAML
      sort: none
      groups: [Contributors, Special Thanks]
      contributors:
        repo: o/r
        role: Code
      users:
        - login: d0kk2bi          # first commit landed; still a special thanks
          group: Contributors
          also_in: [Special Thanks]
        - login: reporter         # never landed one
          group: Special Thanks
          role: Bug reports
      grid:
        columns: 3
        avatar_size: 64
        margin: 8
      YAML

    api_users = [
      ContributorMural::ResolvedUser.new("d0kk2bi", weight: 4, role: "Code"),
      ContributorMural::ResolvedUser.new("newcomer", weight: 1, role: "Code"),
    ]

    run_in_tmp(yaml, github_source: FakeGitHubSource.new(api_users)) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      # Three people on the wall, four drawings, and still three avatars.
      outputs.should contain("user_count=3")
      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      svg.scan(%r{<a href="https://github.com/d0kk2bi"}).size.should eq(2)
      svg.scan(/data:image\/png;base64,/).size.should eq(3)
      # The role the source named reaches them in both sections.
      svg.scan(/<title>d0kk2bi · Code<\/title>/).size.should eq(2)
      svg.should contain("<title>reporter · Bug reports</title>")
      svg.should contain("<title>newcomer · Code</title>")
    end
  end

  # The face alpha is drawn with comes back from the previous wall through the
  # reference in their link, exactly as an inline one would.
  it "salvages a shared face from the wall it is about to replace" do
    yaml = <<-YAML
      sort: none
      groups: [Contributors, Special Thanks]
      users:
        - login: alpha
          group: Contributors
          also_in: [Special Thanks]
        - login: bravo
      YAML

    kept = ""
    run_in_tmp(yaml) do |_exit_code, _outputs, workspace|
      kept = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
    end
    kept.should contain("<symbol id=\"mural-face-1\"")

    seed = ->(workspace : String) { File.write(File.join(workspace, "CONTRIBUTOR_MURAL.svg"), kept); nil }
    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["alpha"]), before: seed) do |exit_code, _outputs, workspace|
      exit_code.should eq(0)
      File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg")).should eq(kept)
    end
  end

  # action.yml declares `svg_path` and the README calls it the alias kept for
  # workflows written before `outputs` existed. It was never emitted, so those
  # workflows read the empty string — an alias failing at the one job it has.
  it "still emits the deprecated svg_path alias" do
    yaml = <<-YAML
      outputs:
        - path: one.svg
        - path: two.svg
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      outputs.should contain("svg_path=one.svg,two.svg")
    end
  end

  # The specs above each pin one output by name, which is what let `svg_path` be
  # declared for three releases without anyone writing it. This closes the set:
  # what a run emits and what `action.yml` promises have to be the same list, so
  # a new output cannot be advertised and left unwired (or emitted and left
  # undocumented).
  it "emits exactly the outputs action.yml declares" do
    yaml = <<-YAML
      outputs:
        - path: wall.svg
        - path: wall.png
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml, rasterizer: FakeRasterizer.new({40, 30})) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      emitted = outputs.each_line.compact_map(&.split('=', 2).first.presence).to_a.sort!.uniq!

      action = YAML.parse(File.read((Path[__DIR__].parent / "action.yml").to_s))
      declared = action["outputs"].as_h.keys.map(&.as_s).sort!

      emitted.should eq(declared)
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

  it "warns when a weave has no role lines to interleave" do
    yaml = <<-YAML
      style: metro
      metro:
        weave: true
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      # The validator still holds an inert `weave` to its `gap` rule, so
      # without this the option passes every check and draws nothing.
      ContributorMural::Annotations.io.to_s
        .should contain("::warning::metro `weave` needs `role_lines`")
    end
  end

  it "stays quiet about a weave that has roles to work with" do
    yaml = <<-YAML
      style: metro
      metro:
        weave: true
        role_lines: true
      users:
        - login: alpha
          role: Core
        - login: bravo
          role: Docs
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      ContributorMural::Annotations.io.to_s.should_not contain("weave")
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

  # Four `users:` entries used to exist purely to attach a role to people the
  # API had already put on the wall — and the next first-time contributor
  # showed up beside them with a blank role line until a human noticed.
  it "draws the source's role for people no users: entry names" do
    yaml = <<-YAML
      sort: none
      contributors:
        repo: o/r
        role: Code
      users:
        - login: hahwul          # curated, says nothing about a role
        - login: reporter        # curated, and not a contributor at all
          role: Bug reports
      grid:
        columns: 3
        avatar_size: 64
        margin: 8
      YAML

    # What the client builds for this config: the source's role on everyone.
    api_users = [
      ContributorMural::ResolvedUser.new("hahwul", weight: 9, role: "Code"),
      ContributorMural::ResolvedUser.new("newcomer", weight: 1, role: "Code"),
    ]

    run_in_tmp(yaml, github_source: FakeGitHubSource.new(api_users)) do |exit_code, _outputs, workspace|
      exit_code.should eq(0)
      svg = File.read(File.join(workspace, "CONTRIBUTOR_MURAL.svg"))
      # The newcomer needs no config entry to get a role line.
      svg.should contain("<title>newcomer · Code</title>")
      # A curated entry that says nothing about a role inherits the source's.
      svg.should contain("<title>hahwul · Code</title>")
      # And one that names its own still wins, even against the source.
      svg.should contain("<title>reporter · Bug reports</title>")
      svg.scan(/font-size="9"/).size.should eq(3)
      # Roles under every face means taller cells: 64 + 18 + 14 label area.
      svg.should contain(%(height="112"))
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

  # An output path is checked for shape at config load, but nothing there can
  # know what is already on disk. A directory sitting where the file goes used
  # to reach the top of the program as an unhandled exception: a Crystal stack
  # trace in the workflow log, and no annotation at all.
  it "reports a path it cannot write as an error rather than a stack trace" do
    yaml = <<-YAML
      output: art/wall.svg
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml, before: ->(workspace : String) {
      Dir.mkdir_p(File.join(workspace, "art/wall.svg"))
    }) do |exit_code, _outputs, _workspace|
      exit_code.should eq(1)
      ContributorMural::Annotations.io.to_s.should contain("::error::could not write art/wall.svg")
    end
  end

  it "reports a directory it cannot create as an error rather than a stack trace" do
    yaml = <<-YAML
      output: art/wall.svg
      users:
        - login: alpha
      YAML

    run_in_tmp(yaml, before: ->(workspace : String) {
      File.write(File.join(workspace, "art"), "in the way")
    }) do |exit_code, _outputs, _workspace|
      exit_code.should eq(1)
      ContributorMural::Annotations.io.to_s.should contain("::error::could not write art/wall.svg")
    end
  end
end

# An avatar host that throttles for a minute used to take people off the wall
# and commit the result, so the picture regressed over a failure that had
# already fixed itself. The file being replaced is the cache.
describe "ContributorMural::Runner avatar salvage" do
  it "keeps the face the previous wall had when this run cannot fetch it" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: alpha
        - login: bravo
      YAML

    good = File.tempname("mural_good")
    Dir.mkdir_p(good)
    begin
      # Render once with everyone reachable, then reuse that file as the wall
      # the flaky run is about to replace.
      config = ContributorMural::Config.parse(yaml)
      config.validate!
      ContributorMural::Runner.new(config, FakeAvatarSource.new, good).run
      previous = File.read(File.join(good, "wall.svg"))

      seed = ->(workspace : String) { File.write(File.join(workspace, "wall.svg"), previous) }
      run_in_tmp(yaml, FakeAvatarSource.new(missing: ["bravo"]), before: seed) do |exit_code, outputs, workspace|
        exit_code.should eq(0)
        File.read(File.join(workspace, "wall.svg")).should eq(previous)
        outputs.should contain("user_count=2")
        log = ContributorMural::Annotations.io.to_s
        log.should contain("::notice::1 person kept the avatar already in the previous output")
        log.should contain("could not fetch theirs: bravo")
        log.should_not contain("skipped bravo")
      end
    ensure
      FileUtils.rm_rf(good)
    end
  end

  # `fail_on_missing` exists to stop someone quietly leaving the picture. A
  # salvaged face means nobody left it, so it must not trip.
  it "does not trip `fail_on_missing` for a face it could salvage" do
    yaml = <<-YAML
      output: wall.svg
      fail_on_missing: true
      users:
        - login: alpha
        - login: bravo
      YAML

    good = File.tempname("mural_good")
    Dir.mkdir_p(good)
    begin
      config = ContributorMural::Config.parse(yaml)
      config.validate!
      ContributorMural::Runner.new(config, FakeAvatarSource.new, good).run
      previous = File.read(File.join(good, "wall.svg"))

      seed = ->(workspace : String) { File.write(File.join(workspace, "wall.svg"), previous) }
      run_in_tmp(yaml, FakeAvatarSource.new(missing: ["bravo"]), before: seed) do |exit_code, outputs, _ws|
        exit_code.should eq(0)
        outputs.should contain("user_count=2")
      end
    ensure
      FileUtils.rm_rf(good)
    end
  end

  it "still drops the person when there is no previous wall to read" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["bravo"])) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      outputs.should contain("user_count=1")
      ContributorMural::Annotations.io.to_s.should contain("::warning::skipped bravo")
    end
  end

  # A person removed from the config, or cut by `exclude`, must not come back
  # just because their face is still sitting in the file.
  it "never reads someone back onto a wall they are no longer on" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: alpha
        - login: bravo
      YAML

    good = File.tempname("mural_good")
    Dir.mkdir_p(good)
    begin
      config = ContributorMural::Config.parse(yaml)
      config.validate!
      ContributorMural::Runner.new(config, FakeAvatarSource.new, good).run
      previous = File.read(File.join(good, "wall.svg"))

      trimmed = <<-YAML
        output: wall.svg
        users:
          - login: alpha
        YAML
      seed = ->(workspace : String) { File.write(File.join(workspace, "wall.svg"), previous) }
      run_in_tmp(trimmed, FakeAvatarSource.new, before: seed) do |exit_code, outputs, workspace|
        exit_code.should eq(0)
        outputs.should contain("user_count=1")
        File.read(File.join(workspace, "wall.svg")).should_not contain("bravo")
      end
    ensure
      FileUtils.rm_rf(good)
    end
  end
end

# Forty per-person warnings scroll past as noise, and a run that lost forty
# people looks exactly like one that lost none.
describe "ContributorMural::Runner missing-avatar reporting" do
  it "counts the people who are not in the mural" do
    yaml = <<-YAML
      users:
        - login: alpha
        - login: bravo
        - login: charlie
        - login: delta
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["bravo"])) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      ContributorMural::Annotations.io.to_s
        .should contain("::warning::1 of 4 person is missing from the mural")
    end
  end

  it "refuses to write a wall missing more than half its people" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: u01
        - login: u02
        - login: u03
        - login: u04
        - login: u05
        - login: u06
        - login: u07
        - login: u08
        - login: u09
        - login: u10
      YAML

    source = FakeAvatarSource.new(missing: (1..6).map { |index| "u%02d" % index })
    run_in_tmp(yaml, source) do |exit_code, _outputs, workspace|
      exit_code.should eq(1)
      File.exists?(File.join(workspace, "wall.svg")).should be_false
      ContributorMural::Annotations.io.to_s
        .should contain("::error::6 of 10 avatars could not be fetched")
    end
  end

  it "leaves the wall already on disk alone when it refuses" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: u01
        - login: u02
        - login: u03
        - login: u04
        - login: u05
        - login: u06
        - login: u07
        - login: u08
        - login: u09
        - login: u10
      YAML

    seed = ->(workspace : String) { File.write(File.join(workspace, "wall.svg"), "PRECIOUS") }
    source = FakeAvatarSource.new(missing: (1..6).map { |index| "u%02d" % index })
    run_in_tmp(yaml, source, before: seed) do |exit_code, _outputs, workspace|
      exit_code.should eq(1)
      File.read(File.join(workspace, "wall.svg")).should eq("PRECIOUS")
    end
  end

  # Without a floor the rule turns ordinary attrition into a workflow that is
  # red forever: two deleted accounts on a wall of three are over any share
  # worth picking, and they will be over it again tomorrow.
  it "does not apply the share to a wall too small to have one" do
    yaml = <<-YAML
      output: wall.svg
      users:
        - login: alpha
        - login: bravo
        - login: charlie
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["alpha", "bravo"])) do |exit_code, outputs, workspace|
      exit_code.should eq(0)
      File.exists?(File.join(workspace, "wall.svg")).should be_true
      outputs.should contain("user_count=1")
    end
  end

  # A target whose own avatars all arrived is complete and has done nothing
  # wrong; the union across targets is for the log line, not for the refusal.
  it "judges the share per target rather than across the run" do
    yaml = <<-YAML
      outputs:
        - path: wall.svg
      users:
        - login: u01
        - login: u02
        - login: u03
        - login: u04
        - login: u05
        - login: u06
        - login: u07
        - login: u08
        - login: u09
        - login: u10
      YAML

    run_in_tmp(yaml, FakeAvatarSource.new(missing: ["u01"])) do |exit_code, outputs, _workspace|
      exit_code.should eq(0)
      outputs.should contain("user_count=9")
      ContributorMural::Annotations.io.to_s
        .should contain("::warning::1 of 10 person is missing from the mural")
    end
  end

  it "stays quiet when everyone is on the wall" do
    yaml = <<-YAML
      users:
        - login: alpha
        - login: bravo
      YAML

    run_in_tmp(yaml) do |exit_code, _outputs, _workspace|
      exit_code.should eq(0)
      ContributorMural::Annotations.io.to_s.should_not contain("not in the mural")
    end
  end
end
