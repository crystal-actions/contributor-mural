require "./spec_helper"

private def config_from(yaml : String) : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

private def api_user(login : String, weight : Int32 = 1, avatar_url : String? = nil) : ContributorMural::ResolvedUser
  ContributorMural::ResolvedUser.new(login: login, avatar_url: avatar_url, weight: weight)
end

describe ContributorMural::Resolver do
  it "resolves list users with defaults" do
    config = config_from(<<-YAML)
      sort: none
      users:
        - login: hahwul
        - login: octocat
          name: The Octocat
          link: https://example.com
      YAML

    users = ContributorMural::Resolver.resolve(config)
    users.map(&.login).should eq(["hahwul", "octocat"])
    users[0].name.should eq("hahwul")
    users[0].link.should eq("https://github.com/hahwul")
    users[0].weight.should eq(1)
    users[1].name.should eq("The Octocat")
    users[1].link.should eq("https://example.com")
  end

  it "sorts by weight descending with login tie-break" do
    config = config_from(<<-YAML)
      users:
        - login: bravo
          weight: 2
        - login: Alpha
          weight: 2
        - login: charlie
          weight: 9
      YAML

    users = ContributorMural::Resolver.resolve(config)
    users.map(&.login).should eq(["charlie", "Alpha", "bravo"])
  end

  it "sorts by login when requested" do
    config = config_from(<<-YAML)
      sort: login
      users:
        - login: bravo
        - login: Alpha
      YAML

    ContributorMural::Resolver.resolve(config).map(&.login).should eq(["Alpha", "bravo"])
  end

  it "applies exclude and limit" do
    config = config_from(<<-YAML)
      sort: none
      exclude: [Bravo]
      limit: 1
      users:
        - login: alpha
        - login: bravo
        - login: charlie
      YAML

    ContributorMural::Resolver.resolve(config).map(&.login).should eq(["alpha"])
  end

  it "excludes by wildcard, matching the literal brackets in a bot login" do
    config = config_from(<<-YAML)
      sort: none
      exclude: ["*[bot]"]
      users:
        - login: alpha
        - login: dependabot[bot]
        - login: renovate[bot]
        - login: octocat
      YAML

    # `octocat` is the check that matters: a `[...]` character class would
    # read this pattern as "ends with b, o, or t" and drop them.
    ContributorMural::Resolver.resolve(config).map(&.login).should eq(["alpha", "octocat"])
  end

  it "matches wildcards case-insensitively, like a plain login" do
    config = config_from(<<-YAML)
      sort: none
      exclude: [ImgBot*, "?eta"]
      users:
        - login: imgbotapp
        - login: beta
        - login: alpha
      YAML

    ContributorMural::Resolver.resolve(config).map(&.login).should eq(["alpha"])
  end

  it "treats a login with no wildcard as an exact match" do
    config = config_from(<<-YAML)
      sort: none
      exclude: [bot]
      users:
        - login: bot
        - login: robot
        - login: bots
      YAML

    ContributorMural::Resolver.resolve(config).map(&.login).should eq(["robot", "bots"])
  end

  it "merges API data into list entries, config fields winning" do
    config = config_from(<<-YAML)
      sort: none
      users:
        - login: hahwul
          name: HAHWUL
      YAML

    api = [api_user("HAHWUL", weight: 42, avatar_url: "https://avatars.example/1"), api_user("newcomer", weight: 3)]
    users = ContributorMural::Resolver.resolve(config, api)

    users.map(&.login).should eq(["hahwul", "newcomer"])
    users[0].name.should eq("HAHWUL")
    users[0].weight.should eq(42)
    users[0].avatar_url.should eq("https://avatars.example/1")
    users[1].weight.should eq(3)
  end

  it "carries a per-user scale through, defaulting everyone else to 1.0" do
    config = config_from(<<-YAML)
      sort: none
      users:
        - login: hahwul
          scale: 1.6
        - login: octocat
      YAML

    users = ContributorMural::Resolver.resolve(config, [api_user("hahwul", weight: 42)])
    users[0].scale.should eq(1.6) # survives the merge with API data
    users[1].scale.should eq(1.0)
  end

  it "keeps both the curated list and API users" do
    config = config_from(<<-YAML)
      sort: none
      contributors: {}
      users:
        - login: listed
      YAML

    api = [api_user("worker")]
    ContributorMural::Resolver.resolve(config, api).map(&.login).should eq(["listed", "worker"])
  end

  it "merges a user appearing in several API sources instead of dropping one" do
    config = config_from("contributors: {}\nsort: none")
    api = [
      ContributorMural::ResolvedUser.new("dup", weight: 42, group: "Contributors"),
      ContributorMural::ResolvedUser.new("Dup", weight: 5, group: "Sponsors", avatar_url: "https://a/x"),
      ContributorMural::ResolvedUser.new("solo", weight: 1, group: "Sponsors"),
    ]

    users = ContributorMural::Resolver.resolve(config, api)
    users.map(&.login).should eq(["dup", "solo"])
    users[0].weight.should eq(42) # highest standing wins
    users[0].group.should eq("Contributors")
    users[0].avatar_url.should eq("https://a/x") # gaps filled from the later entry
  end

  # `name` has no nil to fall through: a source that reports none leaves the
  # login standing in for it. The contributors API never reports one, so
  # first-wins alone would drop the display name a sponsor entry did carry.
  it "fills a placeholder display name from a later API source" do
    config = config_from("contributors: {}\nsort: none")
    api = [
      ContributorMural::ResolvedUser.new("dup", weight: 9),
      ContributorMural::ResolvedUser.new("dup", name: "Real Name", weight: 3),
    ]

    ContributorMural::Resolver.resolve(config, api).first.name.should eq("Real Name")
  end

  it "keeps the first real display name when both sources report one" do
    config = config_from("contributors: {}\nsort: none")
    api = [
      ContributorMural::ResolvedUser.new("dup", name: "First"),
      ContributorMural::ResolvedUser.new("dup", name: "Second"),
    ]

    ContributorMural::Resolver.resolve(config, api).first.name.should eq("First")
  end

  it "keeps config entries out of API groups unless they ask for one" do
    config = config_from(<<-YAML)
      sort: none
      users:
        - login: hahwul
        - login: octocat
          group: Special
      YAML

    api = [api_user("hahwul"), api_user("other")]
    api = api.map { |user| ContributorMural::ResolvedUser.new(user.login, group: "Contributors") }
    users = ContributorMural::Resolver.resolve(config, api)

    users[0].group.should be_nil
    users[1].group.should eq("Special")
    users[2].group.should eq("Contributors")
  end

  it "carries role and group through resolution" do
    config = config_from(<<-YAML)
      sort: none
      users:
        - login: hahwul
          role: Creator
          group: Core
      YAML

    user = ContributorMural::Resolver.resolve(config).first
    user.role.should eq("Creator")
    user.group.should eq("Core")
  end
end

private def embedded(login : String, group : String? = nil) : ContributorMural::EmbeddedUser
  ContributorMural::EmbeddedUser.new(ContributorMural::ResolvedUser.new(login, group: group), "data:,")
end

describe "ContributorMural::Resolver.grouped" do
  it "returns one unnamed section when no groups are used" do
    config = ContributorMural::Config.parse("users:\n  - login: a")
    users = [embedded("a"), embedded("b")]
    sections = ContributorMural::Resolver.grouped(users, config)
    sections.size.should eq(1)
    sections[0][0].should be_nil
    sections[0][1].map(&.login).should eq(["a", "b"])
  end

  it "orders sections by the explicit groups list, ungrouped first" do
    config = ContributorMural::Config.parse(<<-YAML)
      groups: [Core, Thanks]
      users:
        - login: a
      YAML
    users = [embedded("t1", "Thanks"), embedded("c1", "Core"), embedded("solo")]
    sections = ContributorMural::Resolver.grouped(users, config)
    sections.map(&.first).should eq([nil, "Core", "Thanks"])
    sections[2][1].map(&.login).should eq(["t1"])
  end

  it "falls back to first-appearance order from the config" do
    config = ContributorMural::Config.parse(<<-YAML)
      users:
        - login: b1
          group: Beta
        - login: a1
          group: Alpha
      contributors:
        group: Devs
      YAML
    users = [embedded("a1", "Alpha"), embedded("b1", "Beta"), embedded("d1", "Devs")]
    sections = ContributorMural::Resolver.grouped(users, config)
    sections.map(&.first).should eq(["Beta", "Alpha", "Devs"])
  end

  it "drops empty sections" do
    config = ContributorMural::Config.parse("groups: [Ghost]\nusers:\n  - login: a")
    sections = ContributorMural::Resolver.grouped([embedded("a")], config)
    sections.map(&.first).should eq([nil])
  end
end

# `users:` is documented as the list that always wins, and `limit` used to
# overrule it: the cap was applied to the ranking alone, so a contributor with
# enough commits pushed a name someone had written down off the end.
describe "ContributorMural::Resolver limit" do
  it "spends the cap on the API list before touching curated entries" do
    config = config_from(<<-YAML)
      limit: 2
      users:
        - login: alice
        - login: bob
      contributors:
      YAML

    users = ContributorMural::Resolver.resolve(config, [
      api_user("carol", 500), api_user("dave", 400),
    ])
    users.map(&.login).should eq(["alice", "bob"])
  end

  it "keeps render order the sort asked for" do
    config = config_from(<<-YAML)
      limit: 3
      users:
        - login: alice
          weight: 1
      contributors:
      YAML

    users = ContributorMural::Resolver.resolve(config, [
      api_user("carol", 500), api_user("dave", 400), api_user("erin", 300),
    ])
    # Alice is kept because she is curated, not promoted for it.
    users.map(&.login).should eq(["carol", "dave", "alice"])
  end

  it "matches curated entries case-insensitively, as the merge does" do
    config = config_from(<<-YAML)
      limit: 1
      users:
        - login: Alice
      contributors:
      YAML

    users = ContributorMural::Resolver.resolve(config, [api_user("alice", 500), api_user("bob", 400)])
    users.map(&.login).should eq(["Alice"])
  end

  it "still caps, and says so, when `users:` alone is over the limit" do
    io = IO::Memory.new
    previous = ContributorMural::Annotations.io
    ContributorMural::Annotations.io = io
    begin
      config = config_from(<<-YAML)
        sort: none
        limit: 2
        users:
          - login: alice
          - login: bob
          - login: carol
        YAML

      ContributorMural::Resolver.resolve(config).map(&.login).should eq(["alice", "bob"])
    ensure
      ContributorMural::Annotations.io = previous
    end
    io.to_s.should contain("::warning::`limit: 2` is below the 3 curated people still on the wall")
  end

  it "stays quiet when the curated list fits exactly" do
    io = IO::Memory.new
    previous = ContributorMural::Annotations.io
    ContributorMural::Annotations.io = io
    begin
      config = config_from(<<-YAML)
        limit: 2
        users:
          - login: alice
          - login: bob
        contributors:
        YAML

      ContributorMural::Resolver.resolve(config, [api_user("carol", 500)])
        .map(&.login).should eq(["alice", "bob"])
    ensure
      ContributorMural::Annotations.io = previous
    end
    io.to_s.should_not contain("limit")
  end
end

# `exclude` runs before the cap, so the count in the warning is the curated
# people still standing — not the number of lines under `users:`.
describe "ContributorMural::Resolver limit warning" do
  it "counts the curated people still on the wall, not the config's lines" do
    io = IO::Memory.new
    previous = ContributorMural::Annotations.io
    ContributorMural::Annotations.io = io
    begin
      config = config_from(<<-YAML)
        sort: none
        limit: 1
        exclude: [carol]
        users:
          - login: alice
          - login: bob
          - login: carol
        YAML

      ContributorMural::Resolver.resolve(config).map(&.login).should eq(["alice"])
    ensure
      ContributorMural::Annotations.io = previous
    end
    # Two survive `exclude`; saying "3 listed in `users:`" would be a number the
    # reader cannot reconcile with anything.
    io.to_s.should contain("is below the 2 curated people still on the wall")
    io.to_s.should contain("1 of them is not in the mural")
  end
end
