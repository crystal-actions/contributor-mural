require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render(config : ContributorMural::Config) : String
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  # As the runner does. The grid reads the whole list here to size its label
  # gutter, so skipping it measures each section on its own and lets the
  # sections drift apart.
  renderer.prepare(users)
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

  # A person in two sections is drawn twice, and an avatar's base64 is very
  # nearly the whole weight of the file — a second copy of the picture would
  # cost a whole face per extra section.
  it "writes a repeated face once and references it from each section" do
    config = ContributorMural::Config.parse(<<-YAML)
      sort: none
      groups: [Contributors, Special Thanks]
      users:
        - login: hahwul
          group: Contributors
        - login: d0kk2bi
          group: Contributors
          also_in: [Special Thanks]
      grid:
        columns: 4
        avatar_size: 64
        margin: 8
        shape: circle
      YAML

    svg = render(config)
    # Three avatars are drawn (the drawn ones are the indented elements; the
    # <image> inside the <symbol> is the definition, not a drawing).
    svg.scan(/ {4}<image | {4}<g clip-path/).size.should eq(3)
    # hahwul is drawn once, so their bytes stay inline; d0kk2bi's move to a
    # <symbol> and both drawings reference it.
    svg.scan(/data:image\/png;base64,/).size.should eq(2)
    svg.scan(/<symbol id="mural-face-1"/).size.should eq(1)
    svg.scan(/<use href="#mural-face-1"/).size.should eq(2)
    # The reference is clipped exactly as the inline image would have been.
    svg.should contain(%(<g clip-path="url(#avatar-clip)"><use href="#mural-face-1" x="80" y="38" width="64" height="64"/></g>))
    svg.should contain(%(<g clip-path="url(#avatar-clip)"><use href="#mural-face-1" x="8" y="178" width="64" height="64"/></g>))
    # And is inside the person's own link, in both sections.
    svg.scan(%r{<a href="https://github.com/d0kk2bi"}).size.should eq(2)
    Golden.assert("grid_also_in.svg", svg)
  end

  # `prepare` measures the label overhang across the whole document, and a
  # repeated person reaches it once — they are one entry until the bucketing.
  # Their section still has to make room for them, though, which is the block
  # size, not the gutter.
  it "sizes each section around the members it repeats without moving the columns" do
    config = ContributorMural::Config.parse(<<-YAML)
      sort: none
      groups: [Core, Thanks]
      grid:
        columns: 1
        avatar_size: 48
        margin: 8
        truncate: 0
      users:
        - login: a
          name: AVeryLongDisplayNameIndeed
          group: Core
          also_in: [Thanks]
        - login: b
          name: xy
          group: Thanks
      YAML

    svg = render(config)
    # Core holds one row, Thanks two: 30 + (66 + 16) + 12 + 30 + (2*66 + 24)
    svg.should contain(%(height="310"))
    # Every avatar starts in the same column, in both sections.
    columns = svg.scan(/x="([0-9.]+)" y="[0-9.]+" width="48"/).map(&.[1].to_f)
    columns.size.should eq(3)
    columns.uniq.size.should eq(1)
  end

  # Labels are centred on their cell and can be wider than it, so a block takes
  # an inset on both sides to make room. Measured per section, the inset came
  # out different for each, and a group of short names started its avatars tens
  # of pixels left of the group above it — one wall with its columns out of
  # true, purely because one group had longer names.
  it "starts every section's avatars in the same column" do
    config = ContributorMural::Config.parse(<<-YAML)
      sort: none
      groups: [Maintainers, Thanks]
      grid:
        columns: 3
        avatar_size: 48
        truncate: 0
      users:
        - login: a
          name: AVeryLongDisplayNameIndeed
          group: Maintainers
        - login: b
          name: AlsoQuiteLongHere
          group: Maintainers
        - login: c
          name: xy
          group: Thanks
        - login: d
          name: zw
          group: Thanks
      YAML

    columns = render(config).scan(/<image [^>]*x="([0-9.]+)"/).map(&.[1].to_f)
    columns.size.should eq(4)
    # Two per section, two sections: the two column positions repeat exactly.
    columns[0..1].should eq(columns[2..3])
    # And the labels still have their room: nothing starts at the bare margin.
    columns.first.should be > 8.0
  end
end
