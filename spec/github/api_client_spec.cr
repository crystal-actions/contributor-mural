require "../spec_helper"
require "http/server"
require "json"

private def contributor_json(login : String, contributions : Int32, type : String = "User") : String
  {
    login:         login,
    avatar_url:    "https://avatars.example/#{login}",
    html_url:      "https://github.com/#{login}",
    contributions: contributions,
    type:          type,
  }.to_json
end

private ANON_JSON = {
  name:          "Ghost Writer",
  email:         "ghost@example.com",
  type:          "Anonymous",
  contributions: 7,
}.to_json

# Serves canned contributor pages and records request paths+headers.
private def with_api_server(pages : Hash(Int32, String), status : Int32 = 200,
                            headers : HTTP::Headers = HTTP::Headers.new, &)
  seen = [] of {String, String?}
  server = HTTP::Server.new do |context|
    seen << {"#{context.request.path}?#{context.request.query}", context.request.headers["Authorization"]?}
    if status != 200
      headers.each { |key, values| context.response.headers[key] = values }
      context.response.status_code = status
      next
    end
    page = (context.request.query_params["page"]? || "1").to_i
    context.response.content_type = "application/json"
    context.response.print(pages[page]? || "[]")
  end
  address = server.bind_unused_port "127.0.0.1"
  spawn { server.listen }
  begin
    yield "http://#{address}", seen
  ensure
    server.close
  end
end

private def options_from(yaml : String) : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

describe ContributorMural::GitHubApi do
  it "maps contributors to users with contribution weights" do
    pages = {1 => "[#{contributor_json("alice", 42)},#{contributor_json("bob", 3)}]"}
    with_api_server(pages) do |base, _seen|
      api = ContributorMural::GitHubApi.new(api_base: base)
      users = api.contributors("owner/repo")
      users.map(&.login).should eq(["alice", "bob"])
      users[0].weight.should eq(42)
      users[0].avatar_url.should eq("https://avatars.example/alice")
      users[0].link.should eq("https://github.com/alice")
    end
  end

  it "filters bots by default and keeps them when asked" do
    pages = {1 => "[#{contributor_json("human", 5)},#{contributor_json("dependabot[bot]", 9, "Bot")}]"}
    with_api_server(pages) do |base, _seen|
      ContributorMural::GitHubApi.new(api_base: base)
        .contributors("o/r").map(&.login).should eq(["human"])

      options = options_from("contributors:\n  include_bots: true")
      ContributorMural::GitHubApi.new(config: options, api_base: base)
        .contributors("o/r").map(&.login).should eq(["human", "dependabot[bot]"])
    end
  end

  it "paginates until a short page" do
    first_page = (1..100).map { |index| contributor_json("user#{index}", 100 - index + 1) }.join(",")
    pages = {1 => "[#{first_page}]", 2 => "[#{contributor_json("last", 1)}]"}
    with_api_server(pages) do |base, seen|
      options = options_from("contributors:\n  max: 500")
      users = ContributorMural::GitHubApi.new(config: options, api_base: base).contributors("o/r")
      users.size.should eq(101)
      seen.size.should eq(2)
    end
  end

  it "stops at max" do
    first_page = (1..100).map { |index| contributor_json("user#{index}", 1) }.join(",")
    pages = {1 => "[#{first_page}]", 2 => "[#{contributor_json("ignored", 1)}]"}
    with_api_server(pages) do |base, seen|
      options = options_from("contributors:\n  max: 10")
      users = ContributorMural::GitHubApi.new(config: options, api_base: base).contributors("o/r")
      users.size.should eq(10)
      seen.size.should eq(1)
    end
  end

  it "maps anonymous contributors to identicons when enabled" do
    pages = {1 => "[#{ANON_JSON}]"}
    with_api_server(pages) do |base, seen|
      ContributorMural::GitHubApi.new(api_base: base).contributors("o/r").should be_empty

      options = options_from("contributors:\n  include_anonymous: true")
      users = ContributorMural::GitHubApi.new(config: options, api_base: base).contributors("o/r")
      users.size.should eq(1)
      users[0].login.should eq("Ghost Writer")
      users[0].avatar_url.should eq("https://github.com/identicons/Ghost%20Writer.png")
      users[0].link.should eq("https://github.com/o/r/commits?author=ghost%40example.com")
      users[0].weight.should eq(7)
      seen.last[0].should contain("anon=1")
    end
  end

  it "assigns the configured group to fetched contributors" do
    pages = {1 => "[#{contributor_json("alice", 3)}]"}
    with_api_server(pages) do |base, _seen|
      options = options_from("contributors:\n  group: Contributors")
      users = ContributorMural::GitHubApi.new(config: options, api_base: base).contributors("o/r")
      users[0].group.should eq("Contributors")
    end
  end

  it "sends the token as a bearer authorization" do
    pages = {1 => "[]"}
    with_api_server(pages) do |base, seen|
      ContributorMural::GitHubApi.new(token: "sekrit", api_base: base).contributors("o/r")
      seen.last[1].should eq("Bearer sekrit")

      ContributorMural::GitHubApi.new(api_base: base).contributors("o/r")
      seen.last[1].should be_nil
    end
  end

  it "raises a friendly error for missing repositories" do
    with_api_server({} of Int32 => String, status: 404) do |base, _seen|
      expect_raises(ContributorMural::ApiError, /not found or not accessible/) do
        ContributorMural::GitHubApi.new(api_base: base).contributors("o/r")
      end
    end
  end

  it "explains rate limiting with the reset time" do
    headers = HTTP::Headers{"x-ratelimit-remaining" => "0", "x-ratelimit-reset" => "1753400000"}
    with_api_server({} of Int32 => String, status: 403, headers: headers) do |base, _seen|
      error = expect_raises(ContributorMural::ApiError, /rate limit exceeded/) do
        ContributorMural::GitHubApi.new(api_base: base).contributors("o/r")
      end
      message = error.message || ""
      message.should match(/resets at 20\d\d-/)
      message.should contain("pass a `token`")
    end
  end

  it "rejects malformed repo values" do
    expect_raises(ContributorMural::ApiError, /owner\/name/) do
      ContributorMural::GitHubApi.new.contributors("not-a-repo")
    end
  end
end

private def config_with(yaml : String) : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

# Serves REST account lists plus a GraphQL sponsors endpoint.
private def with_sources_server(sponsor_pages : Array(String) = [] of String, &)
  seen = [] of String
  graphql_calls = 0
  server = HTTP::Server.new do |context|
    seen << "#{context.request.method} #{context.request.path}"
    case context.request.path
    when "/orgs/crystal-actions/members"
      context.response.content_type = "application/json"
      context.response.print %([{"login":"member1","avatar_url":"https://a/m1","html_url":"https://github.com/member1"}])
    when "/repos/o/r/stargazers"
      context.response.content_type = "application/json"
      context.response.print %([{"login":"fan1","avatar_url":"https://a/f1"},{"login":"fan2"}])
    when "/graphql"
      context.response.content_type = "application/json"
      body = sponsor_pages[graphql_calls]? || %({"data":{"repositoryOwner":{"sponsorshipsAsMaintainer":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}})
      graphql_calls += 1
      context.response.print body
    else
      context.response.status_code = 404
    end
  end
  address = server.bind_unused_port "127.0.0.1"
  spawn { server.listen }
  begin
    yield "http://#{address}", seen
  ensure
    server.close
  end
end

private SPONSOR_PAGE = {
  data: {
    repositoryOwner: {
      sponsorshipsAsMaintainer: {
        pageInfo: {hasNextPage: false, endCursor: nil},
        nodes:    [
          {
            tier:          {monthlyPriceInDollars: 25},
            sponsorEntity: {login: "bigfan", name: "Big Fan", avatarUrl: "https://a/bf", url: "https://github.com/bigfan"},
          },
          {
            tier:          nil,
            sponsorEntity: {login: "smallfan", name: nil, avatarUrl: nil, url: nil},
          },
        ],
      },
    },
  },
}.to_json

describe "ContributorMural::GitHubApi extra sources" do
  it "fetches organization members with their group" do
    with_sources_server do |base, _seen|
      config = config_with("members:\n  org: crystal-actions\n  group: Team")
      users = ContributorMural::GitHubApi.new(config: config, api_base: base).members("crystal-actions")
      users.map(&.login).should eq(["member1"])
      users[0].group.should eq("Team")
      users[0].weight.should eq(1)
      users[0].avatar_url.should eq("https://a/m1")
    end
  end

  it "fetches stargazers" do
    with_sources_server do |base, _seen|
      config = config_with("stargazers:\n  repo: o/r")
      users = ContributorMural::GitHubApi.new(config: config, api_base: base).stargazers("o/r")
      users.map(&.login).should eq(["fan1", "fan2"])
      users[1].link.should eq("https://github.com/fan2")
    end
  end

  it "fetches sponsors with tier amounts as weights" do
    with_sources_server([SPONSOR_PAGE]) do |base, seen|
      config = config_with("sponsors:\n  login: hahwul\n  group: Sponsors")
      users = ContributorMural::GitHubApi.new(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.login).should eq(["bigfan", "smallfan"])
      users[0].weight.should eq(25)
      users[0].name.should eq("Big Fan")
      users[0].group.should eq("Sponsors")
      users[1].weight.should eq(1)
      users[1].link.should eq("https://github.com/smallfan")
      seen.count(&.starts_with?("POST /graphql")).should eq(1)
    end
  end

  it "skips sponsors whose entity is hidden" do
    hidden = {
      data: {repositoryOwner: {sponsorshipsAsMaintainer: {
        pageInfo: {hasNextPage: false, endCursor: nil},
        nodes:    [{tier: nil, sponsorEntity: nil}, {tier: {monthlyPriceInDollars: 3}, sponsorEntity: {login: "visible"}}],
      }}},
    }.to_json
    with_sources_server([hidden]) do |base, _seen|
      config = config_with("sponsors:\n  login: hahwul")
      users = ContributorMural::GitHubApi.new(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.login).should eq(["visible"])
    end
  end

  it "stops paginating sponsors when the cursor does not advance" do
    stuck = {
      data: {repositoryOwner: {sponsorshipsAsMaintainer: {
        pageInfo: {hasNextPage: true, endCursor: nil},
        nodes:    [{tier: nil, sponsorEntity: {login: "a"}}],
      }}},
    }.to_json
    with_sources_server([stuck, stuck, stuck]) do |base, seen|
      config = config_with("sponsors:\n  login: hahwul\n  max: 50")
      users = ContributorMural::GitHubApi.new(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.login).should eq(["a"])
      seen.count(&.starts_with?("POST /graphql")).should eq(1)
    end
  end

  it "requires a token for sponsors" do
    config = config_with("sponsors:\n  login: hahwul")
    expect_raises(ContributorMural::ApiError, /requires a `token`/) do
      ContributorMural::GitHubApi.new(config: config).sponsors("hahwul")
    end
  end

  it "surfaces GraphQL errors" do
    error_page = %({"errors":[{"message":"Something went wrong"}]})
    with_sources_server([error_page]) do |base, _seen|
      config = config_with("sponsors:\n  login: hahwul")
      expect_raises(ContributorMural::ApiError, /Something went wrong/) do
        ContributorMural::GitHubApi.new(token: "tok", config: config, api_base: base).sponsors("hahwul")
      end
    end
  end

  it "reports unknown sponsor owners" do
    missing = %({"data":{"repositoryOwner":null}})
    with_sources_server([missing]) do |base, _seen|
      config = config_with("sponsors:\n  login: nobody")
      expect_raises(ContributorMural::ApiError, /no user or organization/) do
        ContributorMural::GitHubApi.new(token: "tok", config: config, api_base: base).sponsors("nobody")
      end
    end
  end
end
