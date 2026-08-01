require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render_radial(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

# Ranked users so the size taper and centre pick are predictable. `scales`
# emphasises users by rank index, which is also their drawing order.
private def ranked_users(count : Int32, scales = {} of Int32 => Float64) : String
  String.build do |io|
    io << "users:\n"
    count.times do |index|
      io << "  - login: user#{index.to_s.rjust(2, '0')}\n"
      io << "    weight: #{count - index}\n"
      if scale = scales[index]?
        io << "    scale: #{scale}\n"
      end
    end
  end
end

# Every pair of avatars stays at least as far apart as their two radii, i.e.
# nothing overlaps. The slack is the SVG's two-decimal rounding and nothing
# else: a full half pixel of it used to hide a real overlap in the default
# spiral, so it is set to what the rounding can actually account for — the two
# coordinates and the two sizes, at half an ulp of the last decimal each.
private def assert_no_overlap(placed : Array({Float64, Float64, Float64})) : Nil
  placed.each_combination(2, reuse: true) do |(a, b)|
    distance = Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)
    distance.should be >= (a[2] + b[2]) / 2 - 0.02
  end
end

private def circles(svg : String) : Array({Float64, Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    size = match[3].to_f
    {match[1].to_f + size / 2, match[2].to_f + size / 2, size}
  end
end

# `sort` is a whole-config setting, but it is the renderer that decides whether
# it survives: spiral and orbit each re-sorted the list by weight on their way
# to placing it, so `sort: login` and `sort: none` — which the reference page
# documents as keeping list order, and recommends for keeping the API's own —
# came out weight-ordered anyway. Every style is checked, since the promise is
# made once and kept in seven places.
describe "list order across styles" do
  it "places users in the order `sort` asked for" do
    # Listed against their weights, so any style that re-ranks shows it.
    users = "users:\n  - login: zoe\n    weight: 1\n  - login: yan\n    weight: 2\n  - login: xu\n    weight: 3\n"
    %w[grid honeycomb mosaic voronoi stencil spiral orbit constellation skyline metro].each do |style|
      {
        "none"   => ["zoe", "yan", "xu"],
        "login"  => ["xu", "yan", "zoe"],
        "weight" => ["xu", "yan", "zoe"],
      }.each do |sort, expected|
        svg = render_radial("style: #{style}\nsort: #{sort}\n#{users}")
        drawn = svg.scan(%r{<title>([a-z]+)</title>}).map(&.[1])
        drawn.should eq(expected), "#{style} with sort: #{sort} drew #{drawn}"
      end
    end
  end
end

describe ContributorMural::Renderers::Spiral do
  it "renders the spiral golden file" do
    svg = render_radial("style: spiral\n#{ranked_users(12)}")
    svg.should contain(%(clip-path="url(#spiral-clip)"))
    Golden.assert("spiral.svg", svg)
  end

  it "puts the top contributor at the centre, largest" do
    svg = render_radial("style: spiral\n#{ranked_users(10)}")
    placed = circles(svg)

    placed.first[2].should eq(72.0) # spiral.max_size
    placed.first[2].should be > placed.last[2]

    # The document is square and the first avatar sits at its middle.
    width = svg.match!(/width="([0-9.]+)"/)[1].to_f
    placed.first[0].should be_close(width / 2, 1.0)
    placed.first[1].should be_close(width / 2, 1.0)
  end

  it "keeps avatars from overlapping" do
    assert_no_overlap(circles(render_radial("style: spiral\n#{ranked_users(30)}")))
  end

  # The area estimate the radii start from is tuned against the default taper.
  # A flat taper, a wide one, or simply a longer list all walk out of what it
  # can account for, and each of these overlapped before the radii were checked
  # against the wall rather than trusted to the estimate.
  it "keeps avatars from overlapping whatever the sizes are" do
    {
      {"max_size: 72\n  min_size: 32", 90},   # the defaults, past where they held
      {"max_size: 216\n  min_size: 210", 30}, # a taper flat enough to be no taper
      {"max_size: 282\n  min_size: 226", 30}, # large avatars, shallow taper
      {"max_size: 100\n  min_size: 20", 40},  # a steep one
      {"max_size: 40\n  min_size: 8", 40},    # small avatars
    }.each do |sizes, count|
      svg = render_radial("style: spiral\nspiral:\n  #{sizes}\n#{ranked_users(count)}")
      assert_no_overlap(circles(svg))
    end
  end

  it "draws an emphasised contributor larger, without crowding the bloom" do
    plain = circles(render_radial("style: spiral\n#{ranked_users(30)}"))
    scaled = circles(render_radial("style: spiral\n#{ranked_users(30, {5 => 1.6})}"))

    # Sizes come back off the SVG, so the slack is its two-decimal rounding.
    scaled[5][2].should be_close(plain[5][2] * 1.6, 0.02)
    # The taper still owns everyone else's size; only the placement moves.
    scaled[6][2].should be_close(plain[6][2], 0.02)
    assert_no_overlap(scaled)

    # The area estimate the plain spiral packs by cannot see a neighbour that
    # is half again as wide as its rank says, so the emphasised avatar is
    # cleared outright: a full `gap` from everyone, not merely not touching.
    emphasised = scaled[5]
    scaled.each_with_index do |spot, index|
      next if index == 5
      distance = Math.sqrt((spot[0] - emphasised[0]) ** 2 + (spot[1] - emphasised[1]) ** 2)
      distance.should be >= (spot[2] + emphasised[2]) / 2 + 6 - 0.5 # spiral.gap
    end
  end

  it "fetches an emphasised avatar at its rendered size" do
    config = ContributorMural::Config.parse("style: spiral\n#{ranked_users(4, {0 => 1.5})}")
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Spiral, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(216) # 72 * 1.5 * 2
  end

  it "sizes fetches for the biggest rendering of each avatar" do
    config = ContributorMural::Config.parse("style: spiral\n#{ranked_users(4)}")
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Spiral, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(144) # 72 * 2
    renderer.fetch_size(users.last).should eq(64)   # min_size 32 * 2
  end
end

describe ContributorMural::Renderers::Orbit do
  it "renders the orbit golden file" do
    svg = render_radial("style: orbit\n#{ranked_users(14)}")
    svg.should contain(%(clip-path="url(#orbit-clip)"))
    Golden.assert("orbit.svg", svg)
  end

  it "gives the centre to the top contributor and orbits the rest" do
    svg = render_radial("style: orbit\n#{ranked_users(14)}")
    placed = circles(svg)
    width = svg.match!(/width="([0-9.]+)"/)[1].to_f

    placed.first[2].should eq(104.0) # orbit.center_size
    placed.first[0].should be_close(width / 2, 1.0)
    placed.first[1].should be_close(width / 2, 1.0)

    # Everyone else sits on a ring: same distance from the centre per ring.
    radii = placed[1..].map do |spot|
      Math.sqrt((spot[0] - width / 2) ** 2 + (spot[1] - width / 2) ** 2).round(1)
    end
    radii.uniq.size.should be <= 2
    radii.min.should be > 0
  end

  it "draws one orbit line per ring, themed with the wall" do
    svg = render_radial("style: orbit\n#{ranked_users(14)}")
    rings = svg.scan(/<circle [^>]*stroke-dasharray/)
    rings.size.should be >= 1
    svg.should contain(%(class="mural-ring"))
    svg.should contain(".mural-ring{stroke:#57606a}")
  end

  it "can turn the orbit lines off" do
    svg = render_radial("style: orbit\norbit:\n  rings: false\n#{ranked_users(6)}")
    svg.should_not contain("stroke-dasharray")
  end

  it "renders a single user as just the centre" do
    svg = render_radial("style: orbit\n#{ranked_users(1)}")
    circles(svg).size.should eq(1)
  end

  # A ring used to be filled by arc length, which is longer than the straight
  # line between two neighbours — badly so when a ring holds only two or three,
  # where half a circumference of arc is one diameter of chord. Ring-mates
  # overlapped; a wide `center_size` puts the first ring exactly there.
  it "keeps ring-mates apart when a ring holds only a few" do
    {
      {"center_size: 233\n  avatar_size: 211\n  min_size: 149\n  ring_gap: 19\n  gap: 0", 20},
      {"center_size: 261\n  avatar_size: 213\n  min_size: 136\n  ring_gap: 4\n  gap: 3", 13},
      {"center_size: 56\n  avatar_size: 118\n  min_size: 85\n  ring_gap: 30\n  gap: 1", 39},
    }.each do |orbit, count|
      assert_no_overlap(circles(render_radial("style: orbit\norbit:\n  #{orbit}\n#{ranked_users(count)}")))
    end
  end

  # Stepping out to the next ring reserved half of the ring *after* it, which
  # the taper makes smaller — three pixels short every ring, so anything with a
  # `ring_gap` under that had its rings sitting on each other.
  it "keeps rings apart when the gap between them is small" do
    {
      {"center_size: 150\n  avatar_size: 123\n  min_size: 42\n  ring_gap: 2\n  gap: 31", 37},
      {"center_size: 184\n  avatar_size: 64\n  min_size: 30\n  ring_gap: 2\n  gap: 20", 20},
      {"center_size: 126\n  avatar_size: 247\n  min_size: 133\n  ring_gap: 1\n  gap: 34", 25},
    }.each do |orbit, count|
      assert_no_overlap(circles(render_radial("style: orbit\norbit:\n  #{orbit}\n#{ranked_users(count)}")))
    end
  end

  it "honours `gap` as the clearance it is documented to be" do
    svg = render_radial("style: orbit\norbit:\n  gap: 20\n#{ranked_users(14)}")
    placed = circles(svg)
    placed.each_combination(2, reuse: true) do |(a, b)|
      distance = Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)
      distance.should be >= (a[2] + b[2]) / 2 + 20 - 0.02
    end
  end

  it "draws an emphasised orbiter larger and widens its ring to fit" do
    plain = circles(render_radial("style: orbit\n#{ranked_users(14)}"))
    scaled = circles(render_radial("style: orbit\n#{ranked_users(14, {3 => 2.0})}"))

    scaled[3][2].should eq(112.0) # orbit.avatar_size 56, doubled
    scaled[4][2].should eq(56.0)  # ring-mates keep their own size
    assert_no_overlap(scaled)

    # The extra width is paid for by the ring, not by the people on it: the
    # first ring holds fewer avatars and sits further out than it would have.
    radius_of = ->(spot : {Float64, Float64, Float64}, all : Array({Float64, Float64, Float64})) do
      Math.sqrt((spot[0] - all[0][0]) ** 2 + (spot[1] - all[0][1]) ** 2)
    end
    radius_of.call(scaled[3], scaled).should be > radius_of.call(plain[3], plain)
  end

  it "keeps an emphasised centre clear of the first ring" do
    placed = circles(render_radial("style: orbit\n#{ranked_users(14, {0 => 2.0})}"))
    placed.first[2].should eq(208.0) # orbit.center_size 104, doubled
    assert_no_overlap(placed)
  end
end
