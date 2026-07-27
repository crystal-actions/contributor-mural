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
