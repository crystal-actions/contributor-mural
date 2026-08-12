require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

# {cx, cy, r} — the image box is the disc's bounding square, so the centre and
# the radius come straight back out of it.
private alias Stone = {Float64, Float64, Float64}

private def render_pebble(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private def pebble_users(count : Int32, scales = {} of Int32 => Float64) : String
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

private def stones(svg : String) : Array(Stone)
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    size = match[3].to_f
    {match[1].to_f + size / 2, match[2].to_f + size / 2, size / 2}
  end
end

private def document_size(svg : String) : {Float64, Float64}
  match = svg.match!(/<svg[^>]* width="([0-9.]+)" height="([0-9.]+)"/)
  {match[1].to_f, match[2].to_f}
end

# Nothing overlaps, and the clearance the config asked for is really there. The
# slack is the SVG's two-decimal rounding and nothing else — the two centres and
# the two sizes, at half an ulp of the last decimal each, as radial_spec sets it.
private def assert_clearance(placed : Array(Stone), gap : Float64) : Nil
  placed.each_combination(2, reuse: true) do |(a, b)|
    distance = Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)
    distance.should be >= a[2] + b[2] + gap - 0.02
  end
end

describe ContributorMural::Renderers::Pebble do
  it "renders the pebble golden file" do
    svg = render_pebble(<<-YAML)
      style: pebble
      pebble:
        width: 420
        max_size: 84
        min_size: 30
      #{pebble_users(12)}
      YAML

    svg.should contain(%(<clipPath id="pebble-clip"))
    svg.should contain(%(clip-path="url(#pebble-clip)"))
    Golden.assert("pebble.svg", svg)
  end

  # The small counts are the fragile ones, not the large: with only a handful of
  # discs the edges of the pile dominate, the requested density stops being
  # reachable, and the pack has to loosen itself out of a jam it cannot separate.
  it "never lets two pebbles overlap" do
    ((1..12).to_a + [24, 40, 80]).each do |count|
      svg = render_pebble("style: pebble\n#{pebble_users(count)}")
      placed = stones(svg)
      placed.size.should eq(count)
      assert_clearance(placed, 6.0)
    end
  end

  # A density the crowd cannot be packed to is a request, not a promise: the pile
  # takes the room it needs rather than letting two avatars overlap.
  it "loosens the pile rather than honour a density it cannot reach" do
    {6, 8, 12, 40}.each do |count|
      assert_clearance(stones(render_pebble("style: pebble\npebble:\n  density: 0.9\n#{pebble_users(count)}")), 6.0)
    end

    # And a density it can reach really does pack tighter.
    loose = document_size(render_pebble("style: pebble\npebble:\n  density: 0.25\n#{pebble_users(40)}"))
    packed = document_size(render_pebble("style: pebble\npebble:\n  density: 0.7\n#{pebble_users(40)}"))
    (packed[0] * packed[1]).should be < loose[0] * loose[1]
  end

  it "keeps `gap` as the clearance it is documented to be" do
    {
      {20, 88, 28}, # a wide lead
      {6, 60, 56},  # a nearly flat taper
      {6, 120, 16}, # a steep one
    }.each do |(gap, max_size, min_size)|
      svg = render_pebble(<<-YAML)
        style: pebble
        pebble:
          gap: #{gap}
          max_size: #{max_size}
          min_size: #{min_size}
        #{pebble_users(24)}
        YAML

      assert_clearance(stones(svg), gap.to_f)
    end
  end

  # What separates pebble from the other ten styles: it does not tile. Voronoi's
  # spec asserts the cells cover the block exactly; this one asserts the
  # opposite, and that the pile is still a pack rather than a scatter.
  it "lets the background show between the pebbles" do
    svg = render_pebble("style: pebble\n#{pebble_users(40)}")
    width, height = document_size(svg)
    covered = stones(svg).sum { |(_x, _y, radius)| Math::PI * radius * radius }

    coverage = covered / (width * height)
    coverage.should be < 0.85
    coverage.should be > 0.3
  end

  it "keeps every pebble inside the block it reports" do
    svg = render_pebble("style: pebble\n#{pebble_users(30)}")
    width, height = document_size(svg)

    stones(svg).each do |(x, y, radius)|
      (x - radius).should be >= -0.01
      (y - radius).should be >= -0.01
      (x + radius).should be <= width + 0.01
      (y + radius).should be <= height + 0.01
    end
  end

  it "sizes pebbles by rank, the top contributor largest" do
    svg = render_pebble("style: pebble\n#{pebble_users(20)}")
    radii = stones(svg).map(&.[](2))

    radii.first.should be_close(44.0, 0.02) # max_size 88, halved
    radii.last.should be_close(14.0, 0.02)  # min_size 28, halved
    radii.each_cons_pair { |larger, smaller| smaller.should be <= larger + 0.01 }
  end

  # An all-equal crowd carries no ranking information, which should read as a
  # uniform field at full size rather than as everyone being the smallest.
  it "gives everyone the same pebble when the weights are equal" do
    users = String.build do |io|
      io << "users:\n"
      6.times { |index| io << "  - login: user#{index}\n" }
    end
    radii = stones(render_pebble("style: pebble\n#{users}")).map(&.[](2))

    radii.each(&.should(be_close(44.0, 0.02)))
  end

  it "shrugs off an extreme weight because rank drives the size" do
    users = String.build do |io|
      io << "users:\n  - login: whale\n    weight: 10000\n"
      23.times { |index| io << "  - login: user#{index.to_s.rjust(2, '0')}\n    weight: #{24 - index}\n" }
    end
    radii = stones(render_pebble("style: pebble\n#{users}")).map(&.[](2))

    # Bounded by the config's taper, not by the ratio of the weights.
    (radii.max / radii.min).should be_close(88.0 / 28, 0.01)
  end

  it "draws an emphasised contributor larger without crowding the pack" do
    plain = stones(render_pebble("style: pebble\n#{pebble_users(30)}"))
    scaled = stones(render_pebble("style: pebble\n#{pebble_users(30, {5 => 1.6})}"))

    scaled[5][2].should be_close(plain[5][2] * 1.6, 0.02)
    scaled[6][2].should be_close(plain[6][2], 0.02)
    assert_clearance(scaled, 6.0)
  end

  # The layout memo is an optimisation, not a correctness mechanism: the pack is
  # a pure function of the users and the section ordinal, so a renderer that has
  # already sized a block has to draw exactly what a fresh one would.
  it "packs the same wall however many times it is asked" do
    yaml = "style: pebble\n#{pebble_users(18)}"
    first = render_pebble(yaml)

    config = ContributorMural::Config.parse(yaml)
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(config.style, config)
    renderer.prepare(users)
    embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
      .embed(users, renderer, fail_on_missing: false)
    groups = ContributorMural::Resolver.grouped(embedded, config)

    renderer.render(groups).should eq(first)
    renderer.render(groups).should eq(first)
  end

  it "declares one clip path for the document and clips every avatar with it" do
    svg = render_pebble("style: pebble\ngroups:\n  - core\n  - crew\n#{pebble_users(10)}")

    svg.scan(/<clipPath id="pebble-clip"/).size.should eq(1)
    images = svg.scan(/<image [^>]*>/).map(&.[](0))
    images.size.should eq(10)
    images.each(&.should contain(%(clip-path="url(#pebble-clip)")))
    svg.index!(%(<clipPath id="pebble-clip")).should be < svg.index!(%(url(#pebble-clip)))
  end

  it "offsets the second section below the first" do
    svg = render_pebble(<<-YAML)
      style: pebble
      sort: none
      groups:
        - alpha
        - beta
      users:
        - login: one
          group: alpha
        - login: two
          group: alpha
        - login: three
          group: beta
      YAML

    placed = stones(svg)
    placed.size.should eq(3)
    first = placed.first(2).max_of { |(_x, y, radius)| y + radius }
    placed.last[1].should be > first
  end

  it "renders a single contributor as one pebble" do
    svg = render_pebble("style: pebble\nusers:\n  - login: solo\n")

    stones(svg).size.should eq(1)
    # max_size 88, plus the pad on both sides.
    svg.should contain(%(width="92" height="92"))
  end

  it "fetches an avatar at twice the size it draws it" do
    config = ContributorMural::Config.parse("style: pebble\n#{pebble_users(12, {0 => 1.5})}")
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(config.style, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(264) # 88 * 1.5 * 2
    renderer.fetch_size(users.last).should eq(56)   # 28 * 2
  end

  it "widens the slab it packs into" do
    narrow = document_size(render_pebble("style: pebble\npebble:\n  width: 400\n#{pebble_users(30)}"))
    wide = document_size(render_pebble("style: pebble\npebble:\n  width: 800\n#{pebble_users(30)}"))

    wide[0].should be > narrow[0]
    wide[1].should be < narrow[1]
  end

  # `width` is a cap rather than a target: a crowd big enough to reach it grows
  # downward, and one too small for it makes a smaller pile instead of a sparse
  # line stretched across the whole thing.
  it "treats `width` as the widest the pile may spread" do
    {8, 24, 120}.each do |count|
      width, _height = document_size(render_pebble("style: pebble\npebble:\n  width: 300\n#{pebble_users(count)}"))
      width.should be <= 300 + 2 * 2.0 + 0.01 # the slab, plus the pad on both sides
    end

    small = document_size(render_pebble("style: pebble\npebble:\n  width: 900\n#{pebble_users(6)}"))
    small[0].should be < 500.0
  end

  # `width` is validated against `max_size`, but not against `max_size` times a
  # `scale`. Holding a cap that cannot fit one pebble used to pin the slab at a
  # single pebble wide and stack the crowd into a column thousands of pixels
  # tall — so a cap that asks for the impossible gives way instead.
  it "gives up the width cap rather than stack a scaled pile into a column" do
    everyone = String.build do |io|
      io << "users:\n"
      10.times { |index| io << "  - login: user#{index}\n    weight: #{10 - index}\n    scale: 2\n" }
    end
    svg = render_pebble("style: pebble\npebble:\n  width: 94\n  max_size: 88\n#{everyone}")

    width, height = document_size(svg)
    width.should be > height
    assert_clearance(stones(svg), 6.0)
  end
end
