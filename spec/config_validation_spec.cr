require "./spec_helper"

# `config_spec.cr` covers loading, parsing and the cross-cutting rules. This
# file covers `validate!`'s per-block bounds, which are what a config actually
# trips over: every style has a dozen of them, and each one is the difference
# between a named error at load time and a picture that renders wrong.
#
# The bounds are inclusive ranges, so both ends are asserted — an off-by-one
# in a `(8..512)` rejects a value the README documents as legal.

private def errors_for(yaml : String) : String
  ContributorMural::Config.parse(yaml).validate!
  ""
rescue ex : ContributorMural::ConfigError
  ex.message || ""
end

# Most rules live under a style block, which needs a user list to sit next to.
private def block_errors(yaml : String) : String
  errors_for("users:\n  - login: alpha\n#{yaml}")
end

# {config fragment, expected fragment of the error}
private REJECTED = [
  # grid
  {"grid:\n  columns: 0", "grid `columns` must be between 1 and 100"},
  {"grid:\n  columns: 101", "grid `columns` must be between 1 and 100"},
  {"grid:\n  avatar_size: 7", "grid `avatar_size` must be between 8 and 512"},
  {"grid:\n  avatar_size: 513", "grid `avatar_size` must be between 8 and 512"},
  {"grid:\n  margin: -1", "grid `margin` must be between 0 and 200"},
  {"grid:\n  margin: 201", "grid `margin` must be between 0 and 200"},
  {"grid:\n  truncate: -1", "grid `truncate` must be >= 0"},

  # honeycomb
  {"honeycomb:\n  columns: 0", "honeycomb `columns` must be between 1 and 100"},
  {"honeycomb:\n  columns: 101", "honeycomb `columns` must be between 1 and 100"},
  {"honeycomb:\n  cell_size: 7", "honeycomb `cell_size` must be between 8 and 512"},
  {"honeycomb:\n  cell_size: 513", "honeycomb `cell_size` must be between 8 and 512"},
  {"honeycomb:\n  gap: -1", "honeycomb `gap` must be between 0 and 200"},
  {"honeycomb:\n  gap: 201", "honeycomb `gap` must be between 0 and 200"},

  # mosaic
  {"mosaic:\n  base_cell: 7", "mosaic `base_cell` must be between 8 and 512"},
  {"mosaic:\n  base_cell: 513", "mosaic `base_cell` must be between 8 and 512"},
  {"mosaic:\n  width: 8001", "mosaic `width` must be <= 8000"},
  {"mosaic:\n  gap: -1", "mosaic `gap` must be between 0 and 200"},
  {"mosaic:\n  gap: 201", "mosaic `gap` must be between 0 and 200"},
  {"mosaic:\n  tiers: []", "mosaic `tiers` must not be empty"},
  {"mosaic:\n  tiers: [13]", "mosaic `tiers` values must be between 1 and 12"},
  {"mosaic:\n  tiers: [0]", "mosaic `tiers` values must be between 1 and 12"},

  # spiral
  {"spiral:\n  max_size: 7", "spiral `max_size` must be between 8 and 512"},
  {"spiral:\n  max_size: 513", "spiral `max_size` must be between 8 and 512"},
  {"spiral:\n  min_size: 7", "spiral `min_size` must be between 8 and 512"},
  {"spiral:\n  min_size: 513", "spiral `min_size` must be between 8 and 512"},
  {"spiral:\n  gap: -1", "spiral `gap` must be between 0 and 200"},
  {"spiral:\n  gap: 201", "spiral `gap` must be between 0 and 200"},

  # orbit
  {"orbit:\n  center_size: 7", "orbit `center_size` must be between 8 and 512"},
  {"orbit:\n  center_size: 513", "orbit `center_size` must be between 8 and 512"},
  {"orbit:\n  avatar_size: 513", "orbit `avatar_size` must be between 8 and 512"},
  {"orbit:\n  min_size: 7", "orbit `min_size` must be between 8 and 512"},
  {"orbit:\n  min_size: 513", "orbit `min_size` must be between 8 and 512"},
  {"orbit:\n  ring_gap: 0", "orbit `ring_gap` must be between 1 and 400"},
  {"orbit:\n  ring_gap: 401", "orbit `ring_gap` must be between 1 and 400"},
  {"orbit:\n  gap: -1", "orbit `gap` must be between 0 and 200"},
  {"orbit:\n  gap: 201", "orbit `gap` must be between 0 and 200"},

  # voronoi
  {"voronoi:\n  width: 63", "voronoi `width` must be between 64 and 8000"},
  {"voronoi:\n  width: 8001", "voronoi `width` must be between 64 and 8000"},
  {"voronoi:\n  cell_size: 15", "voronoi `cell_size` must be between 16 and 512"},
  {"voronoi:\n  cell_size: 513", "voronoi `cell_size` must be between 16 and 512"},
  {"voronoi:\n  jitter: 0.9", "voronoi `jitter` must be between 0 and 0.8"},
  {"voronoi:\n  jitter: -0.1", "voronoi `jitter` must be between 0 and 0.8"},
  {"voronoi:\n  weight_influence: 1.1", "voronoi `weight_influence` must be between 0 and 1"},
  {"voronoi:\n  weight_influence: -0.1", "voronoi `weight_influence` must be between 0 and 1"},
  {"voronoi:\n  gap: -1", "voronoi `gap` must be between 0 and 64"},
  {"voronoi:\n  gap: 65", "voronoi `gap` must be between 0 and 64"},
  {"voronoi:\n  rows: 65", "voronoi `rows` must be between 1 and 64"},

  # stencil
  {"stencil:\n  pixel_size: 7", "stencil `pixel_size` must be between 8 and 512"},
  {"stencil:\n  pixel_size: 513", "stencil `pixel_size` must be between 8 and 512"},
  {"stencil:\n  gap: -1", "stencil `gap` must be between 0 and 200"},
  {"stencil:\n  gap: 201", "stencil `gap` must be between 0 and 200"},
  {"stencil:\n  letter_spacing: -1", "stencil `letter_spacing` must be between 0 and 8"},
  {"stencil:\n  letter_spacing: 9", "stencil `letter_spacing` must be between 0 and 8"},
  {"stencil:\n  line_gap: -1", "stencil `line_gap` must be between 0 and 8"},
  {"stencil:\n  line_gap: 9", "stencil `line_gap` must be between 0 and 8"},
  {"stencil:\n  text: \"A\\nB\\nC\\nD\\nE\"", "stencil `text` must be at most 4 lines"},
  {"stencil:\n  text: \"ABCDEFGHIJKLMNOPQ\"", "stencil `text` must be at most 16 characters per line"},

  # constellation
  {"constellation:\n  width: 63", "constellation `width` must be between 64 and 8000"},
  {"constellation:\n  width: 8001", "constellation `width` must be between 64 and 8000"},
  {"constellation:\n  max_size: 513", "constellation `max_size` must be between 8 and 512"},
  {"constellation:\n  min_size: 7", "constellation `min_size` must be between 8 and 512"},
  {"constellation:\n  min_size: 513", "constellation `min_size` must be between 8 and 512"},
  {"constellation:\n  gap: -1", "constellation `gap` must be between 0 and 200"},
  {"constellation:\n  gap: 201", "constellation `gap` must be between 0 and 200"},
  {"constellation:\n  jitter: 1.1", "constellation `jitter` must be between 0 and 1"},
  {"constellation:\n  jitter: -0.1", "constellation `jitter` must be between 0 and 1"},
  {"constellation:\n  dust: -1", "constellation `dust` must be between 0 and 32"},
  {"constellation:\n  dust: 33", "constellation `dust` must be between 0 and 32"},

  # skyline
  {"skyline:\n  width: 63", "skyline `width` must be between 64 and 8000"},
  {"skyline:\n  width: 8001", "skyline `width` must be between 64 and 8000"},
  {"skyline:\n  avatar_size: 7", "skyline `avatar_size` must be between 8 and 512"},
  {"skyline:\n  avatar_size: 513", "skyline `avatar_size` must be between 8 and 512"},
  {"skyline:\n  min_height: 27", "skyline `min_height` must be between 28 and 1024"},
  {"skyline:\n  min_height: 1025", "skyline `min_height` must be between 28 and 1024"},
  {"skyline:\n  max_height: 27", "skyline `max_height` must be between 28 and 1024"},
  {"skyline:\n  max_height: 1025", "skyline `max_height` must be between 28 and 1024"},
  {"skyline:\n  gap: -1", "skyline `gap` must be between 0 and 200"},
  {"skyline:\n  gap: 201", "skyline `gap` must be between 0 and 200"},
  {"skyline:\n  truncate: -1", "skyline `truncate` must be >= 0"},

  # metro
  {"metro:\n  columns: 0", "metro `columns` must be between 1 and 100"},
  {"metro:\n  columns: 101", "metro `columns` must be between 1 and 100"},
  {"metro:\n  station_size: 7", "metro `station_size` must be between 8 and 512"},
  {"metro:\n  station_size: 513", "metro `station_size` must be between 8 and 512"},
  {"metro:\n  line_width: 1", "metro `line_width` must be between 2 and 64"},
  {"metro:\n  line_width: 65", "metro `line_width` must be between 2 and 64"},
  {"metro:\n  gap: -1", "metro `gap` must be between 0 and 200"},
  {"metro:\n  gap: 201", "metro `gap` must be between 0 and 200"},
  {"metro:\n  truncate: -1", "metro `truncate` must be >= 0"},
]

# Values sitting exactly on a documented bound. A `<` written where `<=` was
# meant fails here and nowhere else.
private ACCEPTED = [
  "grid:\n  columns: 1\n  avatar_size: 8\n  margin: 0\n  truncate: 0",
  "grid:\n  columns: 100\n  avatar_size: 512\n  margin: 200",
  "honeycomb:\n  columns: 1\n  cell_size: 8\n  gap: 0",
  "honeycomb:\n  columns: 100\n  cell_size: 512\n  gap: 200",
  "mosaic:\n  width: 8000\n  base_cell: 8\n  gap: 0\n  tiers: [1]",
  "mosaic:\n  base_cell: 512\n  width: 512\n  gap: 200\n  tiers: [12]",
  "spiral:\n  min_size: 8\n  max_size: 8\n  gap: 0",
  "spiral:\n  min_size: 512\n  max_size: 512\n  gap: 200",
  "orbit:\n  center_size: 8\n  avatar_size: 8\n  min_size: 8\n  ring_gap: 1\n  gap: 0",
  "orbit:\n  center_size: 512\n  avatar_size: 512\n  min_size: 512\n  ring_gap: 400\n  gap: 200",
  "voronoi:\n  width: 64\n  cell_size: 64\n  rows: 1\n  jitter: 0\n  weight_influence: 0\n  gap: 0",
  "voronoi:\n  width: 8000\n  cell_size: 512\n  rows: 64\n  jitter: 0.8\n  weight_influence: 1\n  gap: 0",
  "stencil:\n  pixel_size: 8\n  gap: 0\n  letter_spacing: 0\n  line_gap: 0",
  "stencil:\n  pixel_size: 512\n  gap: 200\n  letter_spacing: 8\n  line_gap: 8",
  "stencil:\n  text: \"ABCDEFGHIJKLMNOP\\nB\\nC\\nD\"",
  "constellation:\n  width: 76\n  max_size: 64\n  min_size: 8\n  gap: 12\n  jitter: 0\n  dust: 0",
  "constellation:\n  width: 8000\n  max_size: 512\n  min_size: 512\n  gap: 200\n  jitter: 1\n  dust: 32",
  "skyline:\n  width: 64\n  avatar_size: 8\n  min_height: 28\n  max_height: 28\n  gap: 0\n  truncate: 0",
  "skyline:\n  width: 8000\n  avatar_size: 512\n  min_height: 1024\n  max_height: 1024\n  gap: 200",
  "metro:\n  columns: 1\n  station_size: 8\n  line_width: 4\n  gap: 0\n  truncate: 0",
  "metro:\n  columns: 100\n  station_size: 512\n  line_width: 64\n  gap: 200",
]

describe "ContributorMural::Config#validate! bounds" do
  REJECTED.each do |(fragment, expected)|
    it "rejects #{expected}" do
      block_errors(fragment).should contain(expected)
    end
  end

  ACCEPTED.each do |fragment|
    it "accepts #{fragment.lines.first} on its bounds" do
      block_errors(fragment).should be_empty
    end
  end

  describe "cross-field rules" do
    it "refuses a mosaic narrower than one of its cells" do
      block_errors("mosaic:\n  width: 40\n  base_cell: 48")
        .should contain("mosaic `width` must be >= `base_cell`")
    end

    it "refuses a spiral whose taper runs backwards" do
      block_errors("spiral:\n  min_size: 100\n  max_size: 50")
        .should contain("spiral `min_size` must not exceed `max_size`")
    end

    it "refuses an orbit whose outermost avatar is larger than its ring avatars" do
      block_errors("orbit:\n  avatar_size: 50\n  min_size: 60")
        .should contain("orbit `min_size` must not exceed `avatar_size`")
    end

    it "refuses a voronoi cell wider than the wall it is cut from" do
      block_errors("voronoi:\n  width: 64\n  cell_size: 100\n  gap: 0")
        .should contain("voronoi `cell_size` must not exceed `width`")
    end

    it "refuses a constellation too narrow to hold its largest star and gap" do
      block_errors("constellation:\n  width: 64\n  max_size: 64\n  gap: 12")
        .should contain("constellation `width` must be >= `max_size` plus `gap`")
    end

    it "refuses a skyline whose taper runs backwards" do
      block_errors("skyline:\n  min_height: 300\n  max_height: 200")
        .should contain("skyline `min_height` must not exceed `max_height`")
    end

    # The shortest tower still has to hold its avatar under the roof band.
    it "refuses a skyline whose shortest tower cannot hold its avatar" do
      block_errors("skyline:\n  avatar_size: 200")
        .should contain("skyline `min_height` must be at least `avatar_size` plus 20")
    end

    # A ring thicker than the avatar's radius swallows the face it frames.
    it "refuses a metro rail thick enough to cover its station" do
      block_errors("metro:\n  station_size: 56\n  line_width: 29")
        .should contain("metro `line_width` must not exceed half of `station_size`")
    end

    it "refuses a woven metro whose gap cannot fit the crossing rails" do
      block_errors("metro:\n  weave: true\n  line_width: 8\n  gap: 10")
        .should contain("metro `gap` must be at least 2.5 × `line_width` when `weave` is on")
    end

    # The same gap is fine without the weave, so the rule has to be gated on it.
    it "allows that gap when the weave is off" do
      block_errors("metro:\n  line_width: 8\n  gap: 10").should be_empty
    end
  end
end

describe "ContributorMural::Config#validate! outputs" do
  it "refuses an empty `outputs` list rather than rendering nothing" do
    errors_for("users:\n  - login: alpha\noutputs: []")
      .should contain("`outputs` must not be empty")
  end

  # Both keys set means one of them is silently doing nothing.
  it "refuses `output` and `outputs` together" do
    errors_for("users:\n  - login: alpha\noutput: wall.svg\noutputs:\n  - path: other.svg")
      .should contain("`output` is ignored when `outputs` is set")
  end

  it "keeps `outputs` alone, without the default `output`, valid" do
    errors_for("users:\n  - login: alpha\noutputs:\n  - path: other.svg").should be_empty
  end

  it "refuses an output path that names no file" do
    errors_for(%(users:\n  - login: alpha\noutputs:\n  - path: "   "))
      .should contain("output path must not be empty")
  end

  it "refuses control characters in an output path" do
    errors_for(%(users:\n  - login: alpha\noutputs:\n  - path: "wall\\u0001.svg"))
      .should contain("output path must not contain control characters")
  end

  it "refuses a non-positive png scale" do
    errors_for("users:\n  - login: alpha\npng:\n  scale: 0").should contain("png `scale` must be positive")
    errors_for("users:\n  - login: alpha\npng:\n  scale: -1").should contain("png `scale` must be positive")
  end

  it "caps the png scale at 8" do
    errors_for("users:\n  - login: alpha\npng:\n  scale: 8.1").should contain("png `scale` must be <= 8")
    errors_for("users:\n  - login: alpha\npng:\n  scale: 8").should be_empty
  end
end

describe "ContributorMural::Config#validate! sources" do
  it "refuses a `max` that would fetch nobody" do
    {"contributors", "stargazers", "sponsors"}.each do |section|
      errors_for("#{section}:\n  max: 0").should contain("#{section} `max` must be >= 1")
    end
    errors_for("members:\n  org: crystal-actions\n  max: 0").should contain("members `max` must be >= 1")
  end

  it "refuses a blank members org" do
    errors_for(%(members:\n  org: "  ")).should contain("members `org` must not be empty")
  end

  # The org lands in an API path; anything outside a plain name changes which
  # endpoint is reached.
  it "refuses a members org that is not a plain name" do
    errors_for(%(members:\n  org: "crystal-actions/repo"))
      .should contain("members `org` must be a plain organization name")
    errors_for(%(members:\n  org: ".."))
      .should contain("members `org` must be a plain organization name")
  end

  it "accepts a plain members org" do
    errors_for("members:\n  org: crystal-actions").should be_empty
  end
end

describe "ContributorMural::Config#validate! users" do
  it "refuses a user with no login to fetch" do
    errors_for(%(users:\n  - login: "  ")).should contain("user entry with empty `login`")
  end

  # The link lands in an <a href> inside a committed file, so a scheme that
  # can execute has to be refused before it ever gets written.
  it "refuses a link whose scheme could execute" do
    {"javascript:alert(1)", "data:text/html,<script>", "vbscript:x"}.each do |link|
      errors_for(%(users:\n  - login: alpha\n    link: "#{link}"))
        .should contain("`link` must be http(s), mailto, or a repository-relative path")
    end
  end

  it "accepts the link forms a mural can safely carry" do
    {"https://example.com", "http://example.com", "mailto:a@example.com", "/docs/a.md", "#alpha"}.each do |link|
      errors_for(%(users:\n  - login: alpha\n    link: "#{link}")).should be_empty
    end
  end
end
