require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render_honeycomb(config : ContributorMural::Config) : String
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(ContributorMural::Style::Honeycomb, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

describe ContributorMural::Renderers::Honeycomb do
  it "renders the honeycomb golden file" do
    config = ContributorMural::Config.parse(<<-YAML)
      style: honeycomb
      sort: none
      users:
        - login: one
        - login: two
        - login: three
        - login: four
        - login: five
        - login: six
        - login: seven
      honeycomb:
        columns: 3
        cell_size: 60
        gap: 4
      YAML

    svg = render_honeycomb(config)
    svg.should contain(%(<polygon points="0.5,0 1,0.25 1,0.75 0.5,1 0,0.75 0,0.25"/>))
    svg.should contain(%(clip-path="url(#hex-clip)"))
    Golden.assert("honeycomb.svg", svg)
  end

  it "offsets odd rows and reduces their capacity" do
    config = ContributorMural::Config.parse(<<-YAML)
      style: honeycomb
      sort: none
      users:
        - login: r0c0
        - login: r0c1
        - login: r0c2
        - login: r1c0
        - login: r1c1
        - login: r2c0
      honeycomb:
        columns: 3
        cell_size: 60
        gap: 4
      YAML

    svg = render_honeycomb(config)
    # Row 0 starts at x=4; row 1 (odd, 2 items) shifts half a cell to x=36.
    svg.should contain(%(x="4" y="4"))
    svg.should contain(%(x="36" y="59.96"))
    # Row 2 returns to x=4 at double pitch.
    svg.should contain(%(x="4" y="115.92"))
  end

  it "stacks grouped sections with titles" do
    config = ContributorMural::Config.parse(<<-YAML)
      style: honeycomb
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: Two
      honeycomb:
        columns: 3
        cell_size: 60
        gap: 4
      YAML

    svg = render_honeycomb(config)
    svg.should contain(">One</text>")
    svg.should contain(">Two</text>")
    svg.scan(/<defs>/).size.should eq(1)
    # Second section's hex sits below title(30) + block(~77.28) + gap(12) + title(30)
    svg.should contain(%(y="153.28"))
  end

  it "fetches avatars at twice the cell size" do
    config = ContributorMural::Config.parse("honeycomb:\n  cell_size: 60\nusers:\n  - login: x")
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Honeycomb, config)
    renderer.fetch_size(ContributorMural::ResolvedUser.new("x")).should eq(120)
  end
end
