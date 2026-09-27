require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private PITCH = 24.0 # pixel_size 20 + gap 4
private INSET =  4.0

# A lopsided diamond: wide enough to have a clear middle, and asymmetric so a
# layout that mirrored or transposed the mask would not still pass.
private DIAMOND = <<-ART
  ..###...
  .#####..
  ########
  .######.
  ..####..
  ...##...
  ART

private def mask(art : String = DIAMOND) : ContributorMural::SilhouetteMask
  ContributorMural::SilhouetteMask.parse(art)
end

private def render_silhouette(count : Int32, extra : String = "", art : String = DIAMOND) : String
  config = ContributorMural::Config.parse("style: silhouette\nsilhouette:\n  image: logo.png\n#{extra}#{ranked_users(count)}")
  config.validate!
  users = ContributorMural::Resolver.resolve(config)
  renderer = ContributorMural::Renderer.for(config.style, config, mask: mask(art))
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

private def images(svg : String) : Array({Float64, Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    {match[1].to_f, match[2].to_f, match[3].to_f}
  end
end

private def cell_of(image : {Float64, Float64, Float64}) : {Int32, Int32}
  {((image[0] - INSET) / PITCH).floor.to_i, ((image[1] - INSET) / PITCH).floor.to_i}
end

private def occupied(svg : String) : Set({Int32, Int32})
  images(svg).map { |image| cell_of(image) }.to_set
end

private def ghosts(svg : String) : Int32
  match = svg.match(/<g [^>]*>(.*?)<\/g>/m)
  match ? match[1].scan(/<circle /).size : 0
end

describe ContributorMural::SilhouetteMask do
  it "reads a mask drawn as text" do
    parsed = mask(".#.\n###\n")
    parsed.columns.should eq(3)
    parsed.rows.should eq(2)
    parsed.cells.should eq([{1, 0}, {0, 1}, {1, 1}, {2, 1}])
  end
end

describe ContributorMural::Renderers::Silhouette do
  capacity = mask.cells.size

  it "renders the silhouette golden file" do
    svg = render_silhouette(6)
    svg.should contain(%(clip-path="url(#silhouette-clip)"))
    svg.should contain(".mural-ghost{fill:#57606a}")
    Golden.assert("silhouette.svg", svg)
  end

  it "renders the golden file for a crowd that outgrows the picture" do
    Golden.assert("silhouette_dense.svg", render_silhouette(capacity + 9, "  shape: square\n  ghosts: false\n"))
  end

  it "needs a traced mask to be built at all" do
    config = ContributorMural::Config.parse("style: silhouette\nsilhouette:\n  image: logo.png\nusers:\n  - login: a")
    expect_raises(ArgumentError, /mask/) do
      ContributorMural::Renderer.for(config.style, config)
    end
  end

  it "never drops a contributor, however many turn up" do
    [1, 5, capacity - 1, capacity, capacity + 1, 3 * capacity + 2].each do |count|
      images(render_silhouette(count)).size.should eq(count)
    end
  end

  it "puts every avatar inside the picture" do
    lit = mask.cells.to_set
    [1, 9, capacity + 1, 3 * capacity].each do |count|
      occupied(render_silhouette(count)).each { |cell| lit.should contain(cell) }
    end
  end

  it "starts from the middle, with the heaviest contributor at the centre" do
    svg = render_silhouette(capacity)
    placed = images(svg).map { |image| cell_of(image) }
    # The lit cells' centroid, in cell units: sums of the cell centres.
    centre_x = mask.cells.sum { |(column, _row)| column + 0.5 } / capacity
    centre_y = mask.cells.sum { |(_column, row)| row + 0.5 } / capacity
    distances = placed.map { |(column, row)| (column + 0.5 - centre_x) ** 2 + (row + 0.5 - centre_y) ** 2 }

    # Equal distances come out of the float sums a hair apart, so the order is
    # checked with a tolerance; the renderer itself compares integers.
    distances.each_cons_pair { |near, far| near.should be <= far + 1e-9 }
    svg.index!("user000").should be < svg.index!("user001")
  end

  it "only ever adds to the picture as contributors arrive" do
    previous = Set({Int32, Int32}).new
    (1..capacity + 4).each do |count|
      current = occupied(render_silhouette(count))
      previous.subset_of?(current).should be_true
      current.size.should eq(Math.min(count, capacity))
      previous = current
    end
  end

  it "fills every remaining slot with a ghost, and none once the picture is full" do
    ghosts(render_silhouette(6)).should eq(capacity - 6)
    ghosts(render_silhouette(capacity)).should eq(0)
  end

  it "keeps the picture the same size whoever shows up" do
    small = render_silhouette(1).match!(/width="([0-9.]+)" height="([0-9.]+)"/)
    large = render_silhouette(200).match!(/width="([0-9.]+)" height="([0-9.]+)"/)

    small[1].should eq(large[1])
    small[2].should eq(large[2])
    # 8 columns and 6 rows of pitch, plus the outer inset.
    small[1].should eq("196")
    small[2].should eq("148")
  end

  it "keeps avatars from overlapping" do
    placed = images(render_silhouette(2 * capacity + 3))
    placed.each_combination(2, reuse: true) do |(a, b)|
      apart = a[0] + a[2] <= b[0] + 0.01 || b[0] + b[2] <= a[0] + 0.01 ||
              a[1] + a[2] <= b[1] + 0.01 || b[1] + b[2] <= a[1] + 0.01
      apart.should be_true
    end
  end

  it "fetches someone in two sections for the larger of the two seats" do
    yaml = String.build do |io|
      io << "style: silhouette\nsilhouette:\n  image: logo.png\ngroups: [Crowd, Few]\nusers:\n"
      io << "  - login: star\n    group: Crowd\n    also_in: [Few]\n"
      # Five times the picture's capacity in the crowd, so every seat there is split.
      (5 * capacity).times { |index| io << "  - login: crowd#{index}\n    group: Crowd\n" }
    end
    config = ContributorMural::Config.parse(yaml)
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(config.style, config, mask: mask)
    renderer.prepare(users)

    star = users.find! { |user| user.login == "star" }
    # Alone in `Few` it fills a whole 20px pixel, drawn and fetched at 2x.
    renderer.fetch_size(star).should eq(40)
    renderer.fetch_size(users.find! { |user| user.login == "crowd0" }).should be < 40
  end

  it "breaks ties by reading order, so a symmetric picture fills the same way every time" do
    svg = render_silhouette(4, art: "##\n##\n")
    images(svg).map { |image| cell_of(image) }.should eq([{0, 0}, {1, 0}, {0, 1}, {1, 1}])
  end
end
