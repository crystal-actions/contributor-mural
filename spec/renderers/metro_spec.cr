require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render_metro(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private def metro_users(count : Int32) : String
  String.build do |io|
    io << "users:\n"
    count.times do |index|
      io << "  - login: user#{index.to_s.rjust(3, '0')}\n"
      io << "    weight: #{count - index}\n"
    end
  end
end

# {center x, center y} per station, in drawing order.
private def stations(svg : String) : Array({Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    size = match[3].to_f
    {match[1].to_f + size / 2, match[2].to_f + size / 2}
  end
end

describe ContributorMural::Renderers::Metro do
  it "renders the metro golden file" do
    svg = render_metro("style: metro\nmetro:\n  columns: 3\n#{metro_users(8)}")
    svg.should contain(%(clip-path="url(#metro-clip)"))
    svg.scan(/<defs>/).size.should eq(1)
    Golden.assert("metro.svg", svg)
  end

  # Defaults with six-character logins: outer = 28 + 1.6*8 = 40.8, the corner
  # radius is min(123.6 / 2, 56) = 56, and the margin (56 + 8/2 + 2) clears
  # the loop with its stroke, the rings, and the labels alike.
  it "lays stations on a serpentine: right, turn, and back again" do
    svg = render_metro("style: metro\nmetro:\n  columns: 3\n#{metro_users(8)}")
    placed = stations(svg)
    placed.size.should eq(8)
    placed.first[0].should be_close(62.0, 0.02) # margin
    placed.first[1].should be_close(42.8, 0.02) # top = outer + 2

    rows = placed.group_by(&.[](1)).values
    rows.size.should eq(3)
    rows[0].map(&.[](0)).should eq(rows[0].map(&.[](0)).sort!)          # rightward
    rows[1].map(&.[](0)).should eq(rows[1].map(&.[](0)).sort!.reverse!) # and back
    # Stations sit one pitch apart, a terminus ring funded on both sides:
    # 56 + 2 * 1.6 * 8 + 24.
    (rows[0][1][0] - rows[0][0][0]).should be_close(105.6, 0.02)
  end

  it "runs the route through the station rows, turning with rounded arcs" do
    svg = render_metro("style: metro\nmetro:\n  columns: 3\n#{metro_users(8)}")
    path = svg.match!(/<path d="([^"]+)"/)[1]
    placed = stations(svg)

    path.should start_with("M#{ContributorMural::SVG.num(placed.first[0])},#{ContributorMural::SVG.num(placed.first[1])}")
    # Two 180° turns of two quarter-arcs each; right turns sweep clockwise,
    # left turns counter.
    path.scan(/A56 56 0 0 1/).size.should eq(2)
    path.scan(/A56 56 0 0 0/).size.should eq(2)
    # Every row's y appears in the path — the track passes through the rows.
    placed.map(&.[](1)).uniq!.each do |y|
      path.should contain(",#{ContributorMural::SVG.num(y)}")
    end
  end

  it "gives every section its own line colour, cycling past eight" do
    two = render_metro(<<-YAML)
      style: metro
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: One
        - login: c
          group: Two
        - login: d
          group: Two
      YAML
    strokes = two.scan(/<path [^>]*stroke="(#\w+)"/).map(&.[](1))
    strokes.size.should eq(2)
    strokes.uniq.size.should eq(2)

    yaml = String.build do |io|
      io << "style: metro\nsort: none\nusers:\n"
      9.times do |section|
        io << "  - login: rider#{section}a\n    group: Line#{section}\n"
        io << "  - login: rider#{section}b\n    group: Line#{section}\n"
      end
    end
    nine = render_metro(yaml)
    wrapped = nine.scan(/<path [^>]*stroke="(#\w+)"/).map(&.[](1))
    wrapped.size.should eq(9)
    wrapped.last.should eq(wrapped.first)
  end

  it "marks both ends of the line as termini" do
    svg = render_metro("style: metro\nmetro:\n  columns: 3\n#{metro_users(8)}")
    widths = svg.scan(/<circle [^>]*stroke-width="([0-9.]+)"/).map(&.[](1))
    widths.first.should eq("12.8") # 1.6 * line_width
    widths.last.should eq("12.8")
    widths[1..-2].each(&.should(eq("8")))
  end

  it "renders a lone contributor as a single badge, no track" do
    svg = render_metro("style: metro\n#{metro_users(1)}")
    svg.should_not contain("<path")
    stations(svg).size.should eq(1)
    svg.match!(/<circle [^>]*stroke-width="([0-9.]+)"/)[1].should eq("12.8")
  end

  it "can keep the names off, and truncates the ones it keeps" do
    quiet = render_metro("style: metro\nmetro:\n  show_names: false\n#{metro_users(4)}")
    quiet.should_not contain(%(font-size="11"))

    named = render_metro(<<-YAML)
      style: metro
      users:
        - login: somebody
          name: Somebody Quite Long-Named
      YAML
    named.should contain("…</text>")
  end

  it "splits a wall into one line per role when asked" do
    svg = render_metro(<<-YAML)
      style: metro
      metro:
        role_lines: true
      sort: none
      users:
        - login: ada
          role: Maintainer
        - login: bee
          role: Maintainer
        - login: cal
          role: Contributor
        - login: dot
          role: Contributor
        - login: eve
      YAML

    # Two lines of two get track; the lone unroled rider is a badge.
    strokes = svg.scan(/<path [^>]*stroke="(#\w+)"/).map(&.[](1))
    strokes.should eq(["#e5484d", "#3b82f6"])
    svg.should contain(%(fill="#e5484d">Maintainer</text>))
    svg.should contain(%(fill="#3b82f6">Contributor</text>))
    # The unnamed line carries no title, but its terminus ring is there.
    svg.scan(/font-weight="600"/).size.should eq(2)
    svg.scan(/<circle [^>]*stroke-width/).size.should eq(5)

    # Off by default: the same wall is one line.
    plain = render_metro(<<-YAML)
      style: metro
      sort: none
      users:
        - login: ada
          role: Maintainer
        - login: bee
      YAML
    plain.scan(/<path /).size.should eq(1)
    plain.should_not contain(">Maintainer</text>")
  end

  it "weaves role lines through one another" do
    svg = render_metro(<<-YAML)
      style: metro
      metro:
        columns: 3
        role_lines: true
        weave: true
      sort: none
      users:
        - {login: a1, role: Core}
        - {login: a2, role: Core}
        - {login: a3, role: Core}
        - {login: a4, role: Core}
        - {login: a5, role: Core}
        - {login: a6, role: Core}
        - {login: b1, role: Docs}
        - {login: b2, role: Docs}
        - {login: b3, role: Docs}
        - {login: b4, role: Docs}
      YAML

    strokes = svg.scan(/<path [^>]*stroke="(#\w+)"/).map(&.[](1))
    strokes.should eq(["#e5484d", "#3b82f6"])

    # Rows interleave: Core rides rows 0 and 2 of the shared lattice, Docs
    # rows 1 and 3 — which is what makes the turns cross the other line.
    placed = stations(svg)
    rows = placed.map(&.[](1)).uniq!.sort!
    rows.size.should eq(4)
    placed[0...6].map(&.[](1)).uniq!.sort!.should eq([rows[0], rows[2]])
    placed[6...10].map(&.[](1)).uniq!.sort!.should eq([rows[1], rows[3]])

    # The second line is right-aligned and one column narrower, and its
    # first row runs right to left.
    placed[6...8].map(&.[](0)).should eq(placed[6...8].map(&.[](0)).sort!.reverse!)

    # Woven corners are half a station pitch — the radius that lands every
    # rail midway between two station columns: (56 + 2 × 1.6 × 8 + 24) / 2.
    # The narrow line's first turn drops on the interior side, straight
    # through the wide line's rows: its rail runs at margin 62 + pitch 105.6
    # − 52.8.
    svg.should contain("A52.8 52.8 0 0")
    paths = svg.scan(/<path d="([^"]+)"/).map(&.[](1))
    paths[1].should contain("A52.8 52.8 0 0 0 114.8,")

    # One legend band names both lines in their own colours; no stacked
    # per-line title bands.
    svg.should contain(%(fill="#e5484d">Core</text>))
    svg.should contain(%(fill="#3b82f6">Docs</text>))
    legend_rows = svg.scan(/font-weight="600"[^>]*>[^<]+<\/text>/)
    legend_rows.size.should eq(2)
    ys = svg.scan(/<text [^>]*y="([0-9.]+)"[^>]*font-weight="600"/).map(&.[](1))
    ys.uniq.size.should eq(1)
  end

  it "refuses a weave whose gap cannot clear the rings" do
    config = ContributorMural::Config.parse(<<-YAML)
      style: metro
      metro:
        role_lines: true
        weave: true
        gap: 10
      users:
        - login: a
      YAML
    expect_raises(ContributorMural::ConfigError, /at least 2.5/) { config.validate! }
  end

  it "fetches at double the station size" do
    config = ContributorMural::Config.parse("style: metro\nmetro:\n  station_size: 60\n#{metro_users(2)}")
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Metro, config)
    renderer.fetch_size(ContributorMural::ResolvedUser.new("x")).should eq(120)
  end
end
