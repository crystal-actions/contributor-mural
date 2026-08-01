require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render_constellation(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private def constellation_users(count : Int32, scales = {} of Int32 => Float64) : String
  String.build do |io|
    io << "users:\n"
    count.times do |index|
      io << "  - login: user#{index.to_s.rjust(3, '0')}\n"
      io << "    weight: #{count - index}\n"
      if scale = scales[index]?
        io << "    scale: #{scale}\n"
      end
    end
  end
end

# {center x, center y, size} for every avatar.
private def stars(svg : String) : Array({Float64, Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    size = match[3].to_f
    {match[1].to_f + size / 2, match[2].to_f + size / 2, size}
  end
end

private def lines(svg : String) : Array({Float64, Float64, Float64, Float64})
  svg.scan(/<line x1="([-0-9.]+)" y1="([-0-9.]+)" x2="([-0-9.]+)" y2="([-0-9.]+)"/).map do |match|
    {match[1].to_f, match[2].to_f, match[3].to_f, match[4].to_f}
  end
end

private def assert_gap(placed : Array({Float64, Float64, Float64}), gap : Float64) : Nil
  placed.each_combination(2, reuse: true) do |(a, b)|
    distance = Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)
    distance.should be >= (a[2] + b[2]) / 2 + gap - 0.02
  end
end

describe ContributorMural::Renderers::Constellation do
  it "renders the constellation golden file" do
    svg = render_constellation("style: constellation\n#{constellation_users(12)}")
    svg.should contain(%(clip-path="url(#star-clip)"))
    svg.should contain(%(<radialGradient id="star-glow">))
    Golden.assert("constellation.svg", svg)
  end

  # The lattice is the guarantee: each star keeps to its own cell inset by
  # half the gap, so any two stay a full `gap` apart — whatever the config,
  # the count, or the emphasis.
  it "keeps stars a full gap apart, whatever the config" do
    {
      {"", 1, 12.0},
      {"", 2, 12.0},
      {"", 5, 12.0},
      {"", 40, 12.0},
      {"", 120, 12.0},
      {"constellation:\n  max_size: 200\n  min_size: 190\n  gap: 0\n", 20, 0.0},
      {"constellation:\n  max_size: 512\n  width: 600\n  gap: 20\n", 6, 20.0},
      {"constellation:\n  jitter: 1.0\n", 30, 12.0},
    }.each do |extra, count, gap|
      svg = render_constellation("style: constellation\n#{extra}#{constellation_users(count)}")
      assert_gap(stars(svg), gap)
    end
  end

  it "keeps an emphasised star clear too, at its scaled size" do
    plain = stars(render_constellation("style: constellation\n#{constellation_users(30)}"))
    scaled = stars(render_constellation("style: constellation\n#{constellation_users(30, {3 => 2.0})}"))
    # `scale` doubles the size the taper arrived at; the taper still owns
    # everyone else.
    scaled[3][2].should be_close(plain[3][2] * 2, 0.02)
    scaled[4][2].should be_close(plain[4][2], 0.02)
    assert_gap(scaled, 12.0)
  end

  it "stays inside the configured width" do
    svg = render_constellation("style: constellation\n#{constellation_users(40)}")
    stars(svg).each do |(x, _y, size)|
      (x + size / 2).should be <= 720.02
    end
  end

  # The cell shuffle deals over the whole lattice, so a sky with fewer people
  # than the width has columns used to scatter its stars past the edge of the
  # document it had sized to the people.
  it "keeps a sparse sky inside its own document" do
    [1, 2, 3, 5].each do |count|
      svg = render_constellation("style: constellation\n#{constellation_users(count)}")
      width = svg.match!(/width="([0-9.]+)"/)[1].to_f
      height = svg.match!(/height="([0-9.]+)"/)[1].to_f
      placed = stars(svg)
      placed.size.should eq(count)
      placed.each do |(x, y, size)|
        (x - size / 2).should be >= -0.02
        (x + size / 2).should be <= width + 0.02
        (y - size / 2).should be >= -0.02
        (y + size / 2).should be <= height + 0.02
      end
    end
  end

  it "draws constellation lines between placed stars, and only then" do
    svg = render_constellation("style: constellation\n#{constellation_users(20)}")
    placed = stars(svg)
    drawn = lines(svg)
    drawn.size.should be >= 1
    drawn.size.should be <= placed.size - 1
    svg.should contain(%(class="mural-line"))
    svg.should contain(".mural-line{stroke:#57606a}")

    # Every trimmed endpoint points back at some star's rim.
    drawn.each do |(x1, y1, x2, y2)|
      { {x1, y1}, {x2, y2} }.each do |(x, y)|
        nearest = placed.min_of do |(cx, cy, size)|
          Math.sqrt((cx - x) ** 2 + (cy - y) ** 2) - size / 2
        end
        nearest.should be_close(4.0, 0.02) # LINE_INSET
      end
    end

    off = render_constellation("style: constellation\nconstellation:\n  lines: false\n#{constellation_users(20)}")
    off.should_not contain("<line")
    off.should_not contain("mural-line")
  end

  it "scatters dust only when asked, and never over a face" do
    svg = render_constellation("style: constellation\n#{constellation_users(10)}")
    svg.should contain(%(class="mural-dust"))
    placed = stars(svg)
    dust = svg.scan(/<circle cx="([-0-9.]+)" cy="([-0-9.]+)" r="(0\.[0-9]+|1\.[0-9]+)"\/>/)
    dust.size.should be > 0
    dust.size.should be <= 40 # 10 users * dust 4
    dust.each do |match|
      x = match[1].to_f
      y = match[2].to_f
      placed.each do |(cx, cy, size)|
        Math.sqrt((cx - x) ** 2 + (cy - y) ** 2).should be > size / 2
      end
    end

    off = render_constellation("style: constellation\nconstellation:\n  dust: 0\n#{constellation_users(10)}")
    off.should_not contain("mural-dust")
  end

  it "renders the same sky twice" do
    yaml = "style: constellation\n#{constellation_users(15)}"
    render_constellation(yaml).should eq(render_constellation(yaml))
  end

  it "emits its defs once and stacks sections downward" do
    svg = render_constellation(<<-YAML)
      style: constellation
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: Two
      YAML

    svg.scan(/<defs>/).size.should eq(1)
    svg.scan(/<radialGradient/).size.should eq(1)
    placed = stars(svg)
    placed.size.should eq(2)
    placed[1][1].should be > placed[0][1]
  end

  it "sizes fetches for the taper, the scale included" do
    config = ContributorMural::Config.parse("style: constellation\n#{constellation_users(4, {0 => 1.5})}")
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Constellation, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(192) # max_size 64 * 1.5 * 2
    renderer.fetch_size(users.last).should eq(40)   # min_size 20 * 2
  end
end
