require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render(config : ContributorMural::Config) : String
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private GOLDEN_USERS = <<-YAML
  sort: none
  users:
    - login: hahwul
      name: HAHWUL
    - login: octocat
      name: The Octocat
    - login: long-name-user
      name: An Extremely Long Display Name
    - login: escaper
      name: "R&D <Team>"
    - login: hangul
      name: 한글이름
    - login: plain
  YAML

describe ContributorMural::Renderers::Grid do
  it "renders the circle grid golden file" do
    config = ContributorMural::Config.parse(<<-YAML)
      #{GOLDEN_USERS}
      grid:
        columns: 4
        avatar_size: 64
        margin: 8
        shape: circle
        show_names: true
        truncate: 12
      YAML

    svg = render(config)
    # 296px of avatars + a 4.3px gutter each side so 12-char labels are not clipped
    svg.should contain(%(width="304.6" height="188"))
    svg.should contain("data:image/png;base64,")
    svg.should contain(%(clip-path="url(#avatar-clip)"))
    svg.should contain("R&amp;D &lt;Team&gt;")
    svg.should contain("An Extremel…")
    Golden.assert("grid_circle.svg", svg)
  end

  it "renders the square label-less golden file" do
    config = ContributorMural::Config.parse(<<-YAML)
      #{GOLDEN_USERS}
      theme:
        background: "#0d1117"
      grid:
        columns: 6
        avatar_size: 48
        margin: 4
        shape: square
        show_names: false
      YAML

    svg = render(config)
    svg.should_not contain("clip-path")
    svg.should_not contain("<text")
    svg.should contain(%(.mural-bg{fill:#0d1117}))
    svg.should contain(%(<rect class="mural-bg" width="100%" height="100%"/>))
    Golden.assert("grid_square.svg", svg)
  end

  it "links every avatar to the user's page" do
    config = ContributorMural::Config.parse(GOLDEN_USERS)
    svg = render(config)
    svg.scan(/<a href=/).size.should eq(6)
    svg.should contain(%(href="https://github.com/hahwul"))
  end

  it "renders an empty document without users" do
    config = ContributorMural::Config.parse("contributors: {}")
    svg = ContributorMural::Renderer.for(ContributorMural::Style::Grid, config)
      .render([] of ContributorMural::EmbeddedUser)
    svg.should contain("<svg")
    svg.should_not contain("<image")
  end

  it "renders role lines and taller cells for sections with roles" do
    config = ContributorMural::Config.parse(<<-YAML)
      sort: none
      users:
        - login: hahwul
          name: HAHWUL
          role: Creator
        - login: octocat
      grid:
        columns: 2
        avatar_size: 64
        margin: 8
      YAML

    svg = render(config)
    svg.should contain(%(font-size="9"))
    svg.should contain(">Creator</text>")
    svg.should contain(%(class="mural-role"))
    svg.should contain(%(.mural-role{fill:#6e7781}))
    # label area grows 18 -> 32: height = 1 row * (64+32) + 2*8 = 112
    svg.should contain(%(height="112"))
    svg.should contain("<title>HAHWUL (@hahwul) · Creator</title>")
    Golden.assert("grid_roles.svg", svg)
  end

  it "renders titled sections for grouped users" do
    config = ContributorMural::Config.parse(<<-YAML)
      sort: none
      groups: [Contributors, Special Thanks]
      users:
        - login: hahwul
          group: Contributors
        - login: octocat
          group: Contributors
        - login: torvalds
          role: Sponsor
          group: Special Thanks
      grid:
        columns: 4
        avatar_size: 64
        margin: 8
      YAML

    svg = render(config)
    svg.should contain(">Contributors</text>")
    svg.should contain(">Special Thanks</text>")
    svg.scan(/font-weight="600"/).size.should eq(2)
    svg.scan(/<defs>/).size.should eq(1)
    Golden.assert("grid_groups.svg", svg)
  end
end
