require "../spec_helper"
require "../support/fake_avatar_source"
require "../support/golden"

private PITCH = 28.0 # pixel_size 24 + gap 4
private INSET =  4.0

private def render_stencil(yaml : String) : String
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

private def word(text : String, count : Int32, extra : String = "") : String
  "style: stencil\nstencil:\n  text: #{text}\n#{extra}#{ranked_users(count)}"
end

private def images(svg : String) : Array({Float64, Float64, Float64})
  svg.scan(/<image [^>]*x="([-0-9.]+)" y="([-0-9.]+)" width="([0-9.]+)"/).map do |match|
    {match[1].to_f, match[2].to_f, match[3].to_f}
  end
end

# The lit lattice rebuilt straight from the font table, independently of how
# the renderer walks it.
private def lit(text : String) : Set({Int32, Int32})
  cells = Set({Int32, Int32}).new
  text.each_char_with_index do |char, index|
    origin = index * (ContributorMural::StencilFont::WIDTH + 1)
    ContributorMural::StencilFont.glyph(char).each_with_index do |bits, row|
      bits.each_char_with_index do |bit, column|
        cells << {origin + column, row} if bit == '#'
      end
    end
  end
  cells
end

# Only the ghost group's circles — the avatar clip path is a circle too.
private def ghosts(svg : String) : Int32
  match = svg.match(/<g [^>]*>(.*?)<\/g>/m)
  match ? match[1].scan(/<circle /).size : 0
end

private def occupied(svg : String) : Set({Int32, Int32})
  images(svg).map do |(x, y, _size)|
    {((x - INSET) / PITCH).floor.to_i, ((y - INSET) / PITCH).floor.to_i}
  end.to_set
end

describe ContributorMural::StencilFont do
  it "holds a well-formed 5x7 cell for every character" do
    ContributorMural::StencilFont::GLYPHS.each do |char, rows|
      rows.size.should eq(ContributorMural::StencilFont::HEIGHT)
      rows.each do |bits|
        bits.size.should eq(ContributorMural::StencilFont::WIDTH)
        bits.chars.all?(&.in?('#', '.')).should be_true
      end
      rows.join.includes?('#').should be_true unless char == ' '
    end
  end

  it "describes exactly the characters it can set" do
    expected = ('A'..'Z').to_a + ('0'..'9').to_a + [' ', '-', '.', '!', '?', '+', '\'', '♥']
    ContributorMural::StencilFont::GLYPHS.keys.sort!.should eq(expected.sort!)
    ['-', '.', '!', '?', '+', '\'', '♥'].each do |char|
      ContributorMural::StencilFont::ALPHABET.should contain(char)
    end
  end

  it "folds the emoji heart and uppercases the word" do
    ContributorMural::StencilFont.normalize("thanks \u{2764}\u{FE0F}").should eq("THANKS ♥")
  end
end

describe ContributorMural::Renderers::Stencil do
  capacity = lit("HI").size

  it "renders the stencil golden file" do
    svg = render_stencil(word("HI", 6))
    svg.should contain(%(clip-path="url(#stencil-clip)"))
    svg.should contain(".mural-ghost{fill:#57606a}")
    Golden.assert("stencil.svg", svg)
  end

  it "renders the golden file for a crowd that outgrows the word" do
    Golden.assert("stencil_dense.svg", render_stencil(word("HI", 40)))
  end

  it "renders the golden file without ghosts" do
    svg = render_stencil(word("HI", 6, "  ghosts: false\n  shape: square\n") + "theme:\n  mode: dark\n")
    svg.should_not contain("<circle")
    svg.should_not contain("mural-ghost")
    Golden.assert("stencil_plain.svg", svg)
  end

  it "never drops a contributor, however many turn up" do
    [1, 5, capacity - 1, capacity, capacity + 1, 5 * capacity + 1].each do |count|
      images(render_stencil(word("HI", count))).size.should eq(count)
    end
  end

  it "puts every avatar on a lit pixel of the word" do
    expected = lit("HI")
    [1, 7, capacity + 1, 3 * capacity].each do |count|
      occupied(render_stencil(word("HI", count))).each do |cell|
        expected.should contain(cell)
      end
    end
  end

  it "keeps avatars from overlapping" do
    [capacity + 1, 40, 3 * capacity].each do |count|
      placed = images(render_stencil(word("HI", count)))
      placed.each_combination(2, reuse: true) do |(a, b)|
        apart = a[0] + a[2] <= b[0] + 0.01 || b[0] + b[2] <= a[0] + 0.01 ||
                a[1] + a[2] <= b[1] + 0.01 || b[1] + b[2] <= a[1] + 0.01
        apart.should be_true
      end
    end
  end

  it "keeps the word the same size whoever shows up" do
    small = render_stencil(word("HI", 1)).match!(/width="([0-9.]+)" height="([0-9.]+)"/)
    large = render_stencil(word("HI", 200)).match!(/width="([0-9.]+)" height="([0-9.]+)"/)

    small[1].should eq(large[1])
    small[2].should eq(large[2])
    # 11 columns and 7 rows of pitch, plus the outer inset.
    small[1].should eq("312")
    small[2].should eq("200")
  end

  it "only ever adds to the word as contributors arrive" do
    expected = lit("HI")
    previous = Set({Int32, Int32}).new
    (1..40).each do |count|
      current = occupied(render_stencil(word("HI", count)))
      previous.subset_of?(current).should be_true
      current.size.should eq(Math.min(count, capacity))
      current.should eq(expected) if count >= capacity
      previous = current
    end
  end

  it "fills every remaining slot with a ghost, and none once the word is full" do
    ghosts(render_stencil(word("HI", 6))).should eq(capacity - 6)
    ghosts(render_stencil(word("HI", capacity))).should eq(0)
    # 8 pixels split into a 2x2 grid holding two people, so 2 slots each go spare.
    ghosts(render_stencil(word("HI", capacity + 8))).should eq(16)
  end

  it "starts the word with the heaviest contributor" do
    svg = render_stencil(word("HI", 4))
    first = images(svg).first
    ordered = lit("HI").to_a.sort_by { |(column, row)| {column // 6, row, column} }

    svg.index!("user000").should be < svg.index!("user001")
    {((first[0] - INSET) / PITCH).floor.to_i, ((first[1] - INSET) / PITCH).floor.to_i}
      .should eq(ordered.first)
  end

  it "sizes fetches for the grid each avatar actually lands in" do
    config = ContributorMural::Config.parse(word("HI", capacity + 1))
    users = ContributorMural::Resolver.resolve(config)
    renderer = ContributorMural::Renderer.for(ContributorMural::Style::Stencil, config)
    renderer.prepare(users)

    # The one shared pixel halves its avatars; everyone else stays full size.
    sizes = users.map { |user| renderer.fetch_size(user) }
    sizes.count(24).should eq(2)
    sizes.count(48).should eq(capacity - 1)
  end
end
