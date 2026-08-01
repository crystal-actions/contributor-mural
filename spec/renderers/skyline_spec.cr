require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private def render_skyline(yaml : String) : String
  config = ContributorMural::Config.parse(yaml)
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config)
  renderer.prepare(users)
  embedded, _ = ContributorMural::Embedder.new(FakeAvatarSource.new)
    .embed(users, renderer, fail_on_missing: false)
  renderer.render(ContributorMural::Resolver.grouped(embedded, config))
end

private def skyline_users(count : Int32, scales = {} of Int32 => Float64) : String
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

private alias Rect = {Float64, Float64, Float64, Float64}

private def rects(fragment : String) : Array(Rect)
  fragment.scan(/<rect x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)" height="([0-9.]+)"/).map do |match|
    {match[1].to_f, match[2].to_f, match[3].to_f, match[4].to_f}
  end
end

# One entry per building: {x, top, width, height, baseline}, in drawing order.
# The antenna (2px wide) is left out of the silhouette's measure.
private def buildings(svg : String) : Array({Float64, Float64, Float64, Float64, Float64})
  svg.scan(%r{<g class="mural-building">\n(.*?)</g>}m).map do |match|
    body = rects(match[1]).select { |(_x, _y, w, _h)| w > 2.0 }
    x = body.min_of(&.[](0))
    top = body.min_of(&.[](1))
    width = body.max_of { |(bx, _y, w, _h)| bx + w } - x
    baseline = body.max_of { |(_x, by, _w, h)| by + h }
    {x, top, width, baseline - top, baseline}
  end
end

describe ContributorMural::Renderers::Skyline do
  it "renders the skyline golden file" do
    svg = render_skyline("style: skyline\n#{skyline_users(12)}")
    svg.should contain(%(clip-path="url(#skyline-clip)"))
    svg.should contain(%(class="mural-building"))
    svg.should contain(%(class="mural-ground"))
    Golden.assert("skyline.svg", svg)
  end

  it "inlines its inks in a static mode" do
    svg = render_skyline("style: skyline\ntheme:\n  mode: dark\n#{skyline_users(4)}")
    svg.should contain(%(fill="#21262d"))
    svg.should_not contain("mural-building")
  end

  it "pins the heaviest contributor's tower to max_height exactly" do
    towers = buildings(render_skyline("style: skyline\n#{skyline_users(8)}"))
    towers.first[3].should be_close(220.0, 0.02) # skyline.max_height

    scaled = buildings(render_skyline("style: skyline\n#{skyline_users(8, {0 => 2.0})}"))
    scaled.first[3].should be_close(440.0, 0.02)
    # Everyone else keeps the height their rank set.
    scaled[1][3].should be_close(towers[1][3], 0.02)
  end

  it "keeps the roofline in the order the weights decided" do
    heights = buildings(render_skyline("style: skyline\n#{skyline_users(6)}")).map(&.[](3))
    heights.each_cons_pair do |taller, shorter|
      taller.should be > shorter
    end
  end

  it "breaks up a wall of equals instead of drawing a flat roof" do
    heights = buildings(render_skyline(<<-YAML)).map(&.[](3))
      style: skyline
      users:
      #{String.build { |io| 8.times { |i| io << "  - login: peer#{i}\n    weight: 1\n" } }}
      YAML

    heights.uniq.size.should be > 1
    heights.each do |height|
      height.should be >= 96.0  # skyline.min_height
      height.should be <= 220.0 # skyline.max_height
    end
  end

  it "leaves at least the gap between buildings in a row" do
    towers = buildings(render_skyline("style: skyline\n#{skyline_users(9)}"))
    towers.group_by(&.[](4)).each_value do |row|
      row.sort_by(&.[](0)).each_cons_pair do |left, right|
        (right[0] - (left[0] + left[2])).should be >= 6.0 - 0.02 # skyline.gap
      end
    end
  end

  it "keeps every window inside its building's walls, below the avatar" do
    svg = render_skyline("style: skyline\nskyline:\n  min_height: 180\n  max_height: 320\n#{skyline_users(6)}")
    svg.scan(%r{<a href[^>]*>\n(.*?)</a>}m).each do |anchor|
      body = rects(anchor[1].scan(%r{<g class="mural-building">\n(.*?)</g>}m).first[1])
        .select { |(_x, _y, w, _h)| w > 2.0 }
      left = body.min_of(&.[](0))
      right = body.max_of { |(x, _y, w, _h)| x + w }
      bottom = body.max_of { |(_x, y, _w, h)| y + h }
      image = anchor[1].match!(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9]+)"/)
      floor = image[2].to_f + image[3].to_f

      anchor[1].scan(%r{<g class="mural-window-\w+">\n(.*?)</g>}m).each do |panes|
        rects(panes[1]).each do |(x, y, w, h)|
          x.should be >= left
          (x + w).should be <= right
          y.should be >= floor
          (y + h).should be <= bottom
        end
      end
    end
  end

  it "wraps into further rows, each with its own street" do
    svg = render_skyline("style: skyline\n#{skyline_users(25)}") # 12 columns at the defaults
    svg.scan(/class="mural-ground"/).size.should eq(3)

    single = render_skyline("style: skyline\n#{skyline_users(1)}")
    single.scan(/class="mural-ground"/).size.should eq(1)
    buildings(single).size.should eq(1)
  end

  it "can turn the windows off and the names on" do
    dark = render_skyline("style: skyline\nskyline:\n  windows: false\n#{skyline_users(6)}")
    dark.should_not contain("mural-window")

    named = render_skyline(<<-YAML)
      style: skyline
      skyline:
        show_names: true
      users:
        - login: somebody
          name: Somebody Quite Long-Named
      YAML
    named.should contain(%(font-size="11"))
    named.should contain("…</text>")
  end

  it "emits its defs once across sections" do
    svg = render_skyline(<<-YAML)
      style: skyline
      sort: none
      users:
        - login: a
          group: One
        - login: b
          group: Two
      YAML
    svg.scan(/<defs>/).size.should eq(1)
  end

  it "fetches at double the avatar size, scale or no scale" do
    config = ContributorMural::Config.parse("style: skyline\n#{skyline_users(4, {0 => 2.0})}")
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Skyline, config)
    renderer.prepare(users)

    renderer.fetch_size(users.first).should eq(96) # avatar_size 48 * 2
    renderer.fetch_size(users.last).should eq(96)
  end
end
