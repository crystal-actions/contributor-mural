require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private alias Corner = {Float64, Float64}

private def render_voronoi(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private def ranked_users(count : Int32) : String
  String.build do |io|
    io << "users:\n"
    count.times do |index|
      io << "  - login: user#{index.to_s.rjust(3, '0')}\n"
      io << "    weight: #{count - index}\n"
    end
  end
end

private def cells(svg : String) : Array(Array(Corner))
  svg.scan(/<clipPath id="vcell-\d+"><polygon points="([^"]+)"/).map do |match|
    match[1].split(' ').map do |pair|
      x, y = pair.split(',')
      {x.to_f, y.to_f}
    end
  end
end

private def area(cell : Array(Corner)) : Float64
  total = 0.0
  cell.each_with_index do |current, index|
    following = cell[(index + 1) % cell.size]
    total += current[0] * following[1] - following[0] * current[1]
  end
  (total / 2).abs
end

private def extent(cell : Array(Corner)) : {Float64, Float64}
  xs = cell.map(&.[](0))
  ys = cell.map(&.[](1))
  {xs.max - xs.min, ys.max - ys.min}
end

# A 4x2 lattice of 100x100 cells: width 400 / cell_size 100 gives 4 columns,
# and 8 users fill two even rows.
private def regular_config(gap : Int32, influence : Float64) : String
  <<-YAML
    style: voronoi
    voronoi:
      width: 400
      cell_size: 100
      gap: #{gap}
      jitter: 0
      weight_influence: #{influence}
    YAML
end

describe ContributorMural::Renderers::Voronoi do
  it "renders the voronoi golden file" do
    svg = render_voronoi(<<-YAML)
      style: voronoi
      voronoi:
        width: 512
        cell_size: 128
        gap: 4
        jitter: 0.5
        weight_influence: 0.5
      #{ranked_users(12)}
      YAML

    svg.should contain(%(<clipPath id="vcell-0">))
    svg.should contain(%(clip-path="url(#vcell-0)"))
    Golden.assert("voronoi.svg", svg)
  end

  it "tiles the block exactly when there is no lead" do
    svg = render_voronoi("#{regular_config(0, 0.6)}\n#{ranked_users(25)}")
    covered = cells(svg).sum { |cell| area(cell) }

    width = svg.match!(/width="([0-9.]+)"/)[1].to_f
    height = svg.match!(/height="([0-9.]+)"/)[1].to_f
    covered.should be_close(width * height, width * height * 1e-6)
  end

  it "reduces to a plain lattice without jitter or weighting" do
    svg = render_voronoi("#{regular_config(0, 0.0)}\n#{ranked_users(8)}")
    placed = cells(svg)

    placed.size.should eq(8)
    placed.each do |cell|
      cell.size.should eq(4)
      extent(cell).should eq({100.0, 100.0})
    end
  end

  it "cuts the lead out of shared edges and leaves the boundary flush" do
    placed = cells(render_voronoi("#{regular_config(6, 0.0)}\n#{ranked_users(8)}"))
    sizes = placed.map { |cell| extent(cell) }

    # Corner cells keep two flush edges, so they lose half a lead twice over.
    sizes.should contain({97.0, 97.0})
    # A cell with a neighbour on both sides loses a full lead across.
    sizes.should contain({94.0, 97.0})
    placed.flatten.min_of(&.[](0)).should eq(0.0)
    placed.flatten.max_of(&.[](0)).should eq(400.0)
  end

  it "never lets a cell collapse, whatever the counts or weights" do
    [1, 2, 3, 5, 12, 40].each do |count|
      placed = cells(render_voronoi("style: voronoi\n#{ranked_users(count)}"))
      placed.size.should eq(count)

      areas = placed.map { |cell| area(cell) }
      mean = areas.sum / areas.size
      placed.min_of(&.size).should be >= 3
      areas.min.should be > 0.3 * mean
    end
  end

  it "shrugs off an extreme weight because rank drives the geometry" do
    yaml = String.build do |io|
      io << "style: voronoi\nusers:\n"
      io << "  - login: whale\n    weight: 10000\n"
      23.times { |index| io << "  - login: minnow#{index}\n    weight: 1\n" }
    end

    areas = cells(render_voronoi(yaml)).map { |cell| area(cell) }
    mean = areas.sum / areas.size
    areas.min.should be > 0.3 * mean
    areas.max.should be < 3.0 * mean
  end

  it "gives the heaviest contributor a wider cell" do
    flat = cells(render_voronoi("#{regular_config(0, 0.0)}\n#{ranked_users(8)}"))
    weighted = cells(render_voronoi("#{regular_config(0, 1.0)}\n#{ranked_users(8)}"))

    area(weighted.first).should be > area(flat.first)
    area(weighted.last).should be < area(flat.last)
  end

  it "numbers clip paths across the whole document and declares them first" do
    svg = render_voronoi(<<-YAML)
      style: voronoi
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: Two
        - login: c
          group: Two
      YAML

    ids = svg.scan(/<clipPath id="(vcell-\d+)">/).map(&.[](1))
    ids.should eq(["vcell-0", "vcell-1", "vcell-2"])
    ids.each do |id|
      svg.index!(%(<clipPath id="#{id}">)).should be < svg.index!(%(url(##{id})))
    end
  end

  it "offsets the second section below the first" do
    svg = render_voronoi(<<-YAML)
      style: voronoi
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: Two
      YAML

    tops = cells(svg).map { |cell| cell.min_of(&.[](1)) }
    tops.size.should eq(2)
    tops[1].should be > tops[0]
  end

  it "draws themed outlines only when asked" do
    on = render_voronoi("style: voronoi\nvoronoi:\n  outline: true\n#{ranked_users(6)}")
    on.should contain(%(fill="none" stroke-width="1" class="mural-cell"))
    on.should contain(".mural-cell{stroke:#57606a}")

    off = render_voronoi("style: voronoi\n#{ranked_users(6)}")
    off.should_not contain("mural-cell")
  end

  it "fetches avatars large enough for the widest cell" do
    config = ContributorMural::Config.parse("style: voronoi\n#{ranked_users(4)}")
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Voronoi, config)
    # 720 / 8 columns = 90px pitch, 3x for DPI and heavy-cell slack.
    renderer.fetch_size(ContributorMural::ResolvedUser.new("x")).should eq(270)
  end
end
