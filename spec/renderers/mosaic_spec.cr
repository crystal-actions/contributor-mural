require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private MOSAIC_CONFIG = <<-YAML
  style: mosaic
  users:
    - login: alpha
      weight: 9
    - login: bravo
      weight: 8
    - login: charlie
      weight: 5
    - login: delta
      weight: 4
    - login: echo
      weight: 2
    - login: foxtrot
      weight: 1
  mosaic:
    width: 200
    base_cell: 40
    tiers: [3, 2, 1]
    gap: 2
  YAML

private def render_mosaic(config : ContributorMural::Config) : {ContributorMural::Renderer, String}
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(ContributorMural::Style::Mosaic, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  {renderer, renderer.render(embedded)}
end

describe ContributorMural::Renderers::Mosaic do
  it "renders the mosaic golden file with tiered sizes" do
    config = ContributorMural::Config.parse(MOSAIC_CONFIG)
    _, svg = render_mosaic(config)

    # Top tercile gets 3x3 cells (124px), middle 2x2 (82px), rest 1x1 (40px).
    svg.should contain(%(x="2" y="2" width="124" height="124"))
    svg.should contain(%(x="2" y="128" width="124" height="124"))
    svg.should contain(%(width="82" height="82"))
    svg.should contain(%(x="128" y="2" width="40" height="40"))
    Golden.assert("mosaic.svg", svg)
  end

  it "fetches avatars at twice the tier size" do
    config = ContributorMural::Config.parse(MOSAIC_CONFIG)
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Mosaic, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(240) # span 3 * 40 * 2
    renderer.fetch_size(users.last).should eq(80)   # span 1 * 40 * 2
  end

  it "multiplies the tier span for an emphasised user" do
    # echo sits in the bottom tercile (span 1); 1.5x rounds up to a 2x2 cell,
    # which no `tiers` list could give one person without moving a boundary
    # everyone in that tercile shares.
    config = ContributorMural::Config.parse(MOSAIC_CONFIG.sub("  - login: echo\n    weight: 2\n",
      "  - login: echo\n    weight: 2\n    scale: 1.5\n"))
    users = ContributorMural::Resolver.resolve(config)
    renderer, svg = render_mosaic(config)

    echo = users.find! { |user| user.login == "echo" }
    renderer.fetch_size(echo).should eq(160) # span 2 * 40 * 2
    # charlie and delta hold the middle tier; echo now renders at their size.
    svg.scan(/width="82"/).size.should eq(3)
  end

  it "defaults to span 1 for unknown users" do
    config = ContributorMural::Config.parse(MOSAIC_CONFIG)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Mosaic, config)
    renderer.fetch_size(ContributorMural::ResolvedUser.new("stranger")).should eq(80)
  end
end
