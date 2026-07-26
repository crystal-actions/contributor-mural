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

# Ranked users so the size taper and centre pick are predictable.
private def ranked_users(count : Int32) : String
  String.build do |io|
    io << "users:\n"
    count.times do |index|
      io << "  - login: user#{index.to_s.rjust(2, '0')}\n"
      io << "    weight: #{count - index}\n"
    end
  end
end

private def circles(svg : String) : Array({Float64, Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    size = match[3].to_f
    {match[1].to_f + size / 2, match[2].to_f + size / 2, size}
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
    svg = render_radial("style: spiral\n#{ranked_users(30)}")
    placed = circles(svg)

    placed.each_combination(2, reuse: true) do |(a, b)|
      distance = Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)
      distance.should be >= (a[2] + b[2]) / 2 - 0.5
    end
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
end
