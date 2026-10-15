require "./spec_helper"

describe ContributorMural::Config do
  describe ".load" do
    it "applies defaults for a minimal config" do
      config = ContributorMural::Config.load(SpecHelper.fixture("configs", "minimal.yml"))

      config.style.should eq(ContributorMural::Style::Grid)
      config.output.should eq("CONTRIBUTOR_MURAL.svg")
      config.sort.should eq(ContributorMural::SortMode::Weight)
      config.limit.should be_nil
      config.fail_on_missing?.should be_false
      config.users.size.should eq(1)
      config.users.first.login.should eq("hahwul")
      config.grid.columns.fixed.should eq(8)
      config.grid.max_columns.should eq(10)
      config.grid.shape.should eq(ContributorMural::Shape::Circle)
      config.honeycomb.cell_size.should eq(72)
      config.mosaic.tiers.should eq([3, 2, 1])
      config.theme.mode.should eq(ContributorMural::ThemeMode::Auto)
      config.theme.preset.should eq("github")
      config.theme.light_palette.background.should eq("transparent")
      config.theme.dark_palette.label_color.should eq("#8b949e")
      config.png.scale.should eq(2.0)
      config.render_targets.should eq([{"CONTRIBUTOR_MURAL.svg", ContributorMural::Style::Grid, nil}])
    end

    it "parses every field of a full config" do
      config = ContributorMural::Config.load(SpecHelper.fixture("configs", "full.yml"))

      contributors = config.contributors.should_not be_nil
      contributors.repo.should eq("hahwul/contributor-mural")
      contributors.include_bots?.should be_true
      contributors.max.should eq(50)
      config.exclude.should eq(["dependabot[bot]"])
      config.limit.should eq(60)
      config.fail_on_missing?.should be_true
      config.users.first.name.should eq("HAHWUL")
      config.users.first.weight.should eq(10)
      config.users.first.scale.should eq(1.5)
      config.users[1].avatar_url.should eq("https://example.com/a.png")
      config.grid.shape.should eq(ContributorMural::Shape::Rounded)
      config.grid.show_names?.should be_false
      config.mosaic.tiers.should eq([4, 2, 1])
      config.render_targets.should eq([
        {"docs/grid.svg", ContributorMural::Style::Grid, nil},
        {"docs/hex.svg", ContributorMural::Style::Honeycomb, nil},
        {"docs/wall.png", ContributorMural::Style::Mosaic, ContributorMural::ThemeMode::Dark},
      ])
    end

    it "fails when the file does not exist" do
      expect_raises(ContributorMural::ConfigError, /not found/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "nope.yml"))
      end
    end

    # `exists?` is not `readable?`. A `config` input pointing at a directory —
    # or at a file the container user cannot open — used to reach the top of
    # the program as an unhandled exception, printing a Crystal stack trace
    # into the workflow log and no annotation at all.
    it "fails with a config error when the file cannot be read" do
      directory = File.tempname("mural_cfg_dir")
      Dir.mkdir_p(directory)
      begin
        expect_raises(ContributorMural::ConfigError, /could not be read/) do
          ContributorMural::Config.load(directory)
        end
      ensure
        Dir.delete(directory)
      end
    end

    it "fails on unknown keys (typo protection)" do
      expect_raises(ContributorMural::ConfigError, /avatarsize/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_unknown_key.yml"))
      end
    end

    it "fails when no source would produce any user" do
      expect_raises(ContributorMural::ConfigError, /nothing to render/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_no_users.yml"))
      end
    end

    it "accepts an API-only source without a users list" do
      config = ContributorMural::Config.parse("stargazers:\n  repo: o/r")
      config.validate!
      config.api_sources?.should be_true
    end

    it "enables a source block written with no options under it" do
      config = ContributorMural::Config.parse("contributors:")
      config.validate!
      config.contributors.should_not be_nil
      config.api_sources?.should be_true
    end

    it "combines a users list with a contributors block" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
        contributors:
          repo: o/r
        YAML

      config.validate!
      config.users.size.should eq(1)
      config.contributors.try(&.repo).should eq("o/r")
    end

    it "points at the replacement when the removed `source` key is used" do
      expect_raises(ContributorMural::ConfigError, /`source` was removed/) do
        ContributorMural::Config.parse("source: contributors")
      end
    end

    # Both of these are legal YAML that quietly throws half the file away. The
    # only symptom used to be a wall missing people, which reads as a problem
    # with the sources rather than with the config.
    it "refuses a second YAML document instead of ignoring it" do
      error = expect_raises(ContributorMural::ConfigError, /second YAML document/) do
        ContributorMural::Config.parse("style: honeycomb\nusers:\n  - login: a\n---\nusers:\n  - login: b\n")
      end
      error.line.should eq(4)
    end

    it "still accepts a single document that opens with the marker" do
      config = ContributorMural::Config.parse("---\nstyle: mosaic\nusers:\n  - login: a\n")
      config.style.should eq(ContributorMural::Style::Mosaic)
      config.users.map(&.login).should eq(["a"])
    end

    it "refuses a key set twice instead of keeping only the last" do
      error = expect_raises(ContributorMural::ConfigError, /`users` is set twice/) do
        ContributorMural::Config.parse("style: grid\nusers:\n  - login: a\nusers:\n  - login: b\n")
      end
      error.line.should eq(4)
    end

    it "refuses a key set twice inside a block or a list entry" do
      error = expect_raises(ContributorMural::ConfigError, /`columns` is set twice/) do
        ContributorMural::Config.parse("grid:\n  columns: 3\n  avatar_size: 40\n  columns: 5\nusers:\n  - login: a\n")
      end
      error.line.should eq(4)
      expect_raises(ContributorMural::ConfigError, /`weight` is set twice/) do
        ContributorMural::Config.parse("users:\n  - login: a\n    weight: 5\n    weight: 1\n")
      end
    end

    it "refuses a number that is not finite" do
      {"nan", "NaN", ".inf", "inf"}.each do |value|
        expect_raises(ContributorMural::ConfigError, /Expected a number/) do
          ContributorMural::Config.parse("png:\n  scale: #{value}\nusers:\n  - login: a\n")
        end
      end
    end

    it "asks for an org when `members` is written bare" do
      expect_raises(ContributorMural::ConfigError, /`members` needs an `org`/) do
        ContributorMural::Config.parse("members:")
      end
    end

    # Caught here rather than at the first request, so the error names the file
    # and the line instead of arriving as a puzzling report about GitHub.
    it "rejects a source name that is not a plain GitHub name" do
      {
        "members:\n  org: my-org?x=1"        => /members `org` must be a plain organization name/,
        "members:\n  org: my org"            => /members `org` must be a plain organization name/,
        "contributors:\n  repo: owner/repo?" => /contributors `repo` must look like owner\/name/,
        "contributors:\n  repo: owner"       => /contributors `repo` must look like owner\/name/,
        "stargazers:\n  repo: owner/.."      => /stargazers `repo` must look like owner\/name/,
      }.each do |yaml, message|
        expect_raises(ContributorMural::ConfigError, message) do
          ContributorMural::Config.parse(yaml).validate!
        end
      end
    end

    it "accepts the punctuation GitHub allows in a repository name" do
      ContributorMural::Config.parse("contributors:\n  repo: my-org/some.repo_name").validate!
    end

    it "names the accepted values for a misspelled enum" do
      error = expect_raises(ContributorMural::ConfigError) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_style.yml"))
      end
      message = error.message || ""
      message.should contain(%(unknown value "cubism"))
      message.should contain("grid, honeycomb, mosaic")
      message.should_not contain("ContributorMural::Style")
    end

    it "fails on an unknown style" do
      expect_raises(ContributorMural::ConfigError, /cubism/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_style.yml"))
      end
    end

    it "fails on duplicate logins regardless of case" do
      expect_raises(ContributorMural::ConfigError, /duplicate user login/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_dup_users.yml"))
      end
    end

    it "fails on output paths escaping the repository" do
      expect_raises(ContributorMural::ConfigError, /relative to the repository/) do
        ContributorMural::Config.load(SpecHelper.fixture("configs", "invalid_output.yml"))
      end
    end
  end

  describe "#validate!" do
    it "collects multiple errors into one message" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
            weight: -1
        limit: 0
        grid:
          columns: 0
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain("`weight` must be >= 0")
      message.should contain("`limit` must be >= 1")
      message.should contain("grid `columns` must be between 1 and 100")
    end

    # Two spellings of one file: the run would render both, leave only the
    # second on disk, and still report two paths for it.
    it "rejects two outputs that name the same file" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
        outputs:
          - path: ./docs/wall.svg
          - path: docs/wall.svg
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      (error.message || "").should contain("duplicate output paths")
    end

    it "accepts a per-user scale written as an integer or a decimal" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
            scale: 1.6
          - login: ksg97031
            scale: 2
          - login: octocat
        YAML

      config.validate!
      config.users[0].scale.should eq(1.6)
      config.users[1].scale.should eq(2.0)
      config.users[2].scale.should be_nil
    end

    it "rejects a scale outside the emphasis range" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
            scale: 0.5
          - login: ksg97031
            scale: 4
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain("user hahwul: `scale` must be between 1 and 2")
      message.should contain("user ksg97031: `scale` must be between 1 and 2")
    end

    it "rejects a source weight below 0" do
      config = ContributorMural::Config.parse(<<-YAML)
        contributors:
          weight: -1
        sponsors:
          weight: -3
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain("contributors `weight` must be >= 0")
      message.should contain("sponsors `weight` must be >= 0")
    end

    # The rung below everything a source reports: GitHub counts a contributor
    # from one commit up, so 0 is the only value a curated entry can hold that
    # no measured person can tie with.
    it "accepts a weight of 0 on a curated entry and on a source" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: hahwul
            weight: 0
        stargazers:
          weight: 0
        YAML

      config.validate!
      config.users.first.weight.should eq(0)
    end

    it "parses role and group fields" do
      config = ContributorMural::Config.parse(<<-YAML)
        groups: [Contributors, Special Thanks]
        users:
          - login: hahwul
            role: Creator
            group: Contributors
          - login: octocat
            group: Special Thanks
        contributors:
          group: Contributors
        YAML

      config.validate!
      config.users[0].role.should eq("Creator")
      config.users[0].group.should eq("Contributors")
      config.users[1].role.should be_nil
      config.contributors.try(&.group).should eq("Contributors")
      config.groups.should eq(["Contributors", "Special Thanks"])
    end

    it "parses a role on every source block" do
      config = ContributorMural::Config.parse(<<-YAML)
        contributors:
          role: Code
        members:
          org: crystal-actions
          role: Member
        stargazers:
          role: Star
        sponsors:
          role: Sponsor
        YAML

      config.validate!
      config.contributors.try(&.role).should eq("Code")
      config.members.try(&.role).should eq("Member")
      config.stargazers.try(&.role).should eq("Star")
      config.sponsors.try(&.role).should eq("Sponsor")
    end

    # Nothing is assumed: a role under every face changes the size of the
    # picture, which is not something to do to an existing wall on an upgrade.
    it "leaves every source role nil unless the config writes one" do
      config = ContributorMural::Config.parse("contributors:\nstargazers:\nsponsors:\n")
      config.validate!
      config.contributors.try(&.role).should be_nil
      config.stargazers.try(&.role).should be_nil
      config.sponsors.try(&.role).should be_nil
    end

    # A blank role is not "no role": it draws an empty line under every face
    # and grows the cell to hold it.
    it "rejects a blank role on any source block" do
      config = ContributorMural::Config.parse(<<-YAML)
        contributors:
          role: " "
        members:
          org: crystal-actions
          role: ""
        stargazers:
          role: "\t"
        sponsors:
          role: " "
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      %w[contributors members stargazers sponsors].each do |section|
        message.should contain("#{section} `role` must not be empty")
      end
    end

    it "rejects group values missing from an explicit groups list" do
      config = ContributorMural::Config.parse(<<-YAML)
        groups: [Contributors]
        users:
          - login: hahwul
            group: Contributrs
        contributors:
          group: Nope
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain(%(group "Contributrs" is not listed))
      message.should contain(%(contributors: group "Nope" is not listed))
    end

    it "parses also_in as extra placements alongside group" do
      config = ContributorMural::Config.parse(<<-YAML)
        groups: [Contributors, Special Thanks]
        users:
          - login: d0kk2bi
            group: Contributors
            also_in: [Special Thanks]
          - login: octocat
        YAML

      config.validate!
      config.users[0].also_in.should eq(["Special Thanks"])
      config.users[1].also_in.should be_nil
    end

    # The typo guard has to reach into the list too: an unknown section name is
    # exactly as easy to write there as it is next to `group`, and a placement
    # that silently does nothing is the failure the guard exists to prevent.
    it "rejects also_in values missing from an explicit groups list" do
      config = ContributorMural::Config.parse(<<-YAML)
        groups: [Contributors, Special Thanks]
        users:
          - login: d0kk2bi
            group: Contributors
            also_in: [Special Thnks]
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      (error.message || "").should contain(%(`also_in` group "Special Thnks" is not listed))
    end

    it "rejects also_in entries that are empty, repeated, or the entry's own group" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: blank
            also_in: [" "]
          - login: twice
            also_in: [Thanks, Thanks]
          - login: itself
            group: Contributors
            also_in: [Contributors]
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain("user blank: `also_in` entries must not be empty")
      message.should contain("user twice: duplicate `also_in` entries")
      message.should contain(%(user itself: `also_in` repeats `group` "Contributors"))
    end

    it "rejects duplicate or empty groups entries" do
      config = ContributorMural::Config.parse(<<-YAML)
        groups: [A, A, " "]
        users:
          - login: hahwul
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain("must not be empty")
      message.should contain("duplicate `groups`")
    end

    it "rejects unsupported output extensions" do
      config = ContributorMural::Config.parse(<<-YAML)
        output: art.txt
        users:
          - login: hahwul
        YAML

      expect_raises(ContributorMural::ConfigError, /end with .svg or .png/) { config.validate! }
    end

    it "names the character a stencil word cannot set, and what it can" do
      config = ContributorMural::Config.parse("users:\n  - login: a\nstencil:\n  text: \"R&D @ 5\"")
      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      message = error.message || ""
      message.should contain(%(unsupported characters: "&", "@"))
      message.should contain("A-Z, 0-9, space")
    end

    it "rejects a stencil word with nothing to draw" do
      config = ContributorMural::Config.parse("users:\n  - login: a\nstencil:\n  text: \"   \"")
      expect_raises(ContributorMural::ConfigError, /at least one letter, digit, or symbol/) do
        config.validate!
      end
    end

    it "accepts a lowercase stencil word and an emoji heart" do
      config = ContributorMural::Config.parse("users:\n  - login: a\nstencil:\n  text: \"thanks \u{2764}\u{FE0F}\"")
      config.validate!
      config.stencil.glyph_lines.first.should eq("THANKS ♥".chars)
    end

    it "caps the voronoi lead against the cell it has to fit inside" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: a
        voronoi:
          cell_size: 40
          jitter: 0.5
          gap: 9
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      (error.message || "").should contain("voronoi `gap` must be at most 5")
    end

    it "rejects a voronoi row count outside the range" do
      config = ContributorMural::Config.parse(<<-YAML)
        users:
          - login: a
        voronoi:
          rows: 0
        YAML

      error = expect_raises(ContributorMural::ConfigError) { config.validate! }
      (error.message || "").should contain("voronoi `rows` must be between 1 and 64")
    end
  end
end

describe "local avatar validation" do
  it "rejects local avatar paths escaping the repository" do
    config = ContributorMural::Config.parse(<<-YAML)
      users:
        - login: a
          avatar_url: ../secrets.png
        - login: b
          avatar_url: /etc/logo.png
        - login: c
          avatar_url: assets/ok.png
      YAML

    error = expect_raises(ContributorMural::ConfigError) { config.validate! }
    message = error.message || ""
    message.should contain("user a: local `avatar_url`")
    message.should contain("user b: local `avatar_url`")
    message.should_not contain("user c")
  end
end

# `columns: auto` is the only config value that decides a number rather than
# being one, so its arithmetic is asserted here rather than only through a
# rendered wall.
private def grid(yaml : String) : ContributorMural::GridConfig
  ContributorMural::Config.parse("users:\n  - login: a\ngrid:\n#{yaml}").grid
end

describe "grid columns" do
  it "reads a fixed count as a ceiling, never wider than the headcount" do
    fixed = grid("  columns: 8")
    fixed.columns.auto?.should be_false
    fixed.columns_for(3).should eq(3)
    fixed.columns_for(8).should eq(8)
    fixed.columns_for(20).should eq(8)
  end

  it "keeps an auto wall on one row until max_columns, then splits it evenly" do
    auto = grid("  columns: auto")
    auto.columns.auto?.should be_true
    auto.columns_for(6).should eq(6)
    auto.columns_for(10).should eq(10)
    # 11 people are 6 and 5, not 10 and a lone face underneath.
    auto.columns_for(11).should eq(6)
    auto.columns_for(16).should eq(8)
    auto.columns_for(30).should eq(10)
  end

  it "honours max_columns as the widest auto row" do
    auto = grid("  columns: auto\n  max_columns: 4")
    auto.columns_for(4).should eq(4)
    auto.columns_for(5).should eq(3)
    auto.columns_for(12).should eq(4)
  end

  # Rows divide by the column count, so a wall nobody is on must not ask for
  # zero columns.
  it "never reports fewer than one column" do
    grid("  columns: auto").columns_for(0).should eq(1)
    grid("  columns: 8").columns_for(0).should eq(1)
  end

  it "names `auto` when the value is neither a number nor it" do
    error = expect_raises(ContributorMural::ConfigError) do
      ContributorMural::Config.parse("users:\n  - login: a\ngrid:\n  columns: nine\n")
    end
    (error.message || "").should contain(%(Expected a number or "auto", not "nine"))
  end

  it "rejects a fixed count outside the range, naming auto as the alternative" do
    error = expect_raises(ContributorMural::ConfigError) do
      ContributorMural::Config.parse("users:\n  - login: a\ngrid:\n  columns: 101\n").validate!
    end
    (error.message || "").should contain("grid `columns` must be between 1 and 100, or `auto`")
  end
end
