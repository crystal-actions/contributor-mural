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

# Same as the avatar source: a client that built its own pool holds a
# connection open until it is handed back.
private OPENED_CLIENTS = [] of ContributorMural::GitHubApi

Spec.after_each do
  OPENED_CLIENTS.each(&.close)
  OPENED_CLIENTS.clear
end

private def github_api(*args, **options) : ContributorMural::GitHubApi
  client = ContributorMural::GitHubApi.new(*args, **options)
  OPENED_CLIENTS << client
  client
end

private def options_from(yaml : String) : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

describe ContributorMural::GitHubApi do
  it "maps contributors to users with contribution weights" do
    pages = {1 => "[#{contributor_json("alice", 42)},#{contributor_json("bob", 3)}]"}
    with_api_server(pages) do |base, _seen|
      api = github_api(api_base: base)
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
      github_api(api_base: base)
        .contributors("o/r").map(&.login).should eq(["human"])

      options = options_from("contributors:\n  include_bots: true")
      github_api(config: options, api_base: base)
        .contributors("o/r").map(&.login).should eq(["human", "dependabot[bot]"])
    end
  end

  it "paginates until a short page" do
    first_page = (1..100).map { |index| contributor_json("user#{index}", 100 - index + 1) }.join(",")
    pages = {1 => "[#{first_page}]", 2 => "[#{contributor_json("last", 1)}]"}
    with_api_server(pages) do |base, seen|
      options = options_from("contributors:\n  max: 500")
      users = github_api(config: options, api_base: base).contributors("o/r")
      users.size.should eq(101)
      seen.size.should eq(2)
    end
  end

  it "stops at max" do
    first_page = (1..100).map { |index| contributor_json("user#{index}", 1) }.join(",")
    pages = {1 => "[#{first_page}]", 2 => "[#{contributor_json("ignored", 1)}]"}
    with_api_server(pages) do |base, seen|
      options = options_from("contributors:\n  max: 10")
      users = github_api(config: options, api_base: base).contributors("o/r")
      users.size.should eq(10)
      seen.size.should eq(1)
    end
  end

  it "maps anonymous contributors to identicons when enabled" do
    pages = {1 => "[#{ANON_JSON}]"}
    with_api_server(pages) do |base, seen|
      github_api(api_base: base).contributors("o/r").should be_empty

      options = options_from("contributors:\n  include_anonymous: true")
      users = github_api(config: options, api_base: base).contributors("o/r")
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
      users = github_api(config: options, api_base: base).contributors("o/r")
      users[0].group.should eq("Contributors")
    end
  end

  it "flattens contribution counts onto the source weight when set" do
    pages = {1 => "[#{contributor_json("alice", 3540)},#{contributor_json("bob", 2)}]"}
    with_api_server(pages) do |base, _seen|
      options = options_from("contributors:\n  weight: 1")
      users = github_api(config: options, api_base: base).contributors("o/r")
      users.map(&.weight).should eq([1, 1])
    end
  end

  it "applies the source weight to anonymous contributors too" do
    pages = {1 => "[#{ANON_JSON}]"}
    with_api_server(pages) do |base, _seen|
      options = options_from("contributors:\n  include_anonymous: true\n  weight: 4")
      users = github_api(config: options, api_base: base).contributors("o/r")
      users.map(&.weight).should eq([4])
    end
  end

  it "sends the token as a bearer authorization" do
    pages = {1 => "[]"}
    with_api_server(pages) do |base, seen|
      github_api(token: "sekrit", api_base: base).contributors("o/r")
      seen.last[1].should eq("Bearer sekrit")

      github_api(api_base: base).contributors("o/r")
      seen.last[1].should be_nil
    end
  end

  it "raises a friendly error for missing repositories" do
    with_api_server({} of Int32 => String, status: 404) do |base, _seen|
      expect_raises(ContributorMural::ApiError, /not found or not accessible/) do
        github_api(api_base: base).contributors("o/r")
      end
    end
  end

  it "explains rate limiting with the reset time" do
    headers = HTTP::Headers{"x-ratelimit-remaining" => "0", "x-ratelimit-reset" => "1753400000"}
    with_api_server({} of Int32 => String, status: 403, headers: headers) do |base, _seen|
      error = expect_raises(ContributorMural::ApiError, /rate limit exceeded/) do
        github_api(api_base: base).contributors("o/r")
      end
      message = error.message || ""
      message.should match(/resets at 20\d\d-/)
      message.should contain("pass a `token`")
    end
  end

  it "rejects malformed repo values" do
    expect_raises(ContributorMural::ApiError, /owner\/name/) do
      github_api.contributors("not-a-repo")
    end
  end
end

private def config_with(yaml : String) : ContributorMural::Config
  ContributorMural::Config.parse(yaml)
end

# Serves `last_page` pages of contributors, advertising the last one through a
# `Link` header the way GitHub does, and records both the pages requested and how
# many requests were ever in flight at once.
private class PaginatedServer
  getter pages_seen = [] of Int32
  getter peak_in_flight = 0
  getter address : String

  def initialize(@last_page : Int32, @bot_pages : Array(Int32) = [] of Int32,
                 @delay : Time::Span = 20.milliseconds)
    in_flight = 0
    @server = HTTP::Server.new do |context|
      page = (context.request.query_params["page"]? || "1").to_i
      @pages_seen << page
      in_flight += 1
      @peak_in_flight = in_flight if in_flight > @peak_in_flight
      sleep @delay
      in_flight -= 1

      context.response.content_type = "application/json"
      context.response.headers["Link"] = link_header(page)
      # Full pages everywhere but the last, so nothing stops the walk early.
      count = page < @last_page ? 100 : 40
      context.response.print("[#{page_body(page, count)}]")
    end
    @address = "http://#{@server.bind_unused_port("127.0.0.1")}"
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end

  private def page_body(page : Int32, count : Int32) : String
    type = @bot_pages.includes?(page) ? "Bot" : "User"
    (1..count).map { |index| contributor_json("p#{page}u#{index}", count - index + 1, type) }.join(",")
  end

  private def link_header(page : Int32) : String
    parts = [%(<https://api/x?page=#{@last_page}>; rel="last")]
    parts << %(<https://api/x?page=#{page + 1}>; rel="next") if page < @last_page
    parts.join(", ")
  end
end

private def with_paginated_server(last_page : Int32, bot_pages : Array(Int32) = [] of Int32, &)
  server = PaginatedServer.new(last_page, bot_pages)
  begin
    yield server
  ensure
    server.close
  end
end

describe "ContributorMural::GitHubApi throttling" do
  it "waits out a secondary rate limit and carries on" do
    # The burst limit names its own delay and clears on its own, unlike an
    # exhausted hourly quota. Telling the two apart is what keeps a run that
    # tripped a momentary limit from failing outright.
    calls = 0
    server = HTTP::Server.new do |context|
      calls += 1
      if calls < 3
        context.response.status_code = 429
        context.response.headers["Retry-After"] = "0"
      else
        context.response.content_type = "application/json"
        context.response.print "[#{contributor_json("late", 1)}]"
      end
    end
    address = server.bind_unused_port "127.0.0.1"
    spawn { server.listen }
    begin
      api = github_api(api_base: "http://#{address}", backoff_base: 0.seconds)
      api.contributors("o/r").map(&.login).should eq(["late"])
      calls.should eq(3)
    ensure
      server.close
    end
  end

  it "does not retry an exhausted hourly quota, even when asked to wait" do
    headers = HTTP::Headers{
      "x-ratelimit-remaining" => "0",
      "x-ratelimit-reset"     => "1753400000",
      "Retry-After"           => "0",
    }
    with_api_server({} of Int32 => String, status: 429, headers: headers) do |base, seen|
      expect_raises(ContributorMural::ApiError, /rate limit exceeded/) do
        github_api(api_base: base, backoff_base: 0.seconds).contributors("o/r")
      end
      # The quota resets on the hour, so waiting the named moment would only
      # spend attempts on the same answer.
      seen.size.should eq(1)
    end
  end
end

describe "ContributorMural::GitHubApi pagination" do
  it "fetches the pages after the first together, in order" do
    with_paginated_server(4) do |server|
      options = config_with("contributors:\n  max: 1000")
      users = github_api(config: options, api_base: server.address).contributors("o/r")

      users.size.should eq(340) # three full pages plus a last page of forty
      users.first.login.should eq("p1u1")
      users.last.login.should eq("p4u40")
      server.pages_seen.sort.should eq([1, 2, 3, 4])
      # Page 1 goes alone because it is what names the last page; 2 through 4
      # then go out together instead of as three waits in a row.
      server.peak_in_flight.should eq(3)
    end
  end

  it "still stops as soon as the caller has enough people" do
    with_paginated_server(20) do |server|
      options = config_with("contributors:\n  max: 50")
      users = github_api(config: options, api_base: server.address).contributors("o/r")

      users.size.should eq(50)
      # Twenty pages exist; wanting fifty people still costs one request.
      server.pages_seen.should eq([1])
    end
  end

  it "does not fan out past the pages `max` can still use" do
    # A window is requested before any of it is read, so the size of that bet
    # has to come from what the caller still wants. Twenty pages exist and a
    # hundred and fifty people are asked for: page two finishes the job, and
    # the three pages beside it would be bought and thrown away — the cheapest
    # requests to save on a quota of sixty an hour.
    with_paginated_server(20) do |server|
      options = config_with("contributors:\n  max: 150")
      users = github_api(config: options, api_base: server.address).contributors("o/r")

      users.size.should eq(150)
      server.pages_seen.sort.should eq([1, 2])
    end
  end

  it "keeps walking when filtering eats whole pages" do
    # `max` cannot bound the page count by itself: bots are dropped after the
    # fetch, so a page can yield nobody at all. Planning off the `Link` header
    # rather than off `max` is what keeps the real people from going missing.
    with_paginated_server(3, bot_pages: [1, 2]) do |server|
      options = config_with("contributors:\n  max: 40")
      users = github_api(config: options, api_base: server.address).contributors("o/r")

      users.size.should eq(40)
      users.first.login.should eq("p3u1")
      server.pages_seen.sort.should eq([1, 2, 3])
    end
  end
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

describe "ContributorMural::GitHubApi name checks" do
  # These all used to be pasted straight into the request path. `?` folded the
  # rest of the route — and this client's own pagination — into a query string
  # and reached a different endpoint; `#` truncated the path; `..` walked up
  # out of it. Every one of them came back as an error about GitHub.
  it "refuses a repo that would change which path is requested" do
    api = github_api(api_base: "http://127.0.0.1:1")
    [
      "owner/repo?per_page=1", "owner/repo#frag", "owner/..", "../owner/repo",
      "owner//repo", "owner", "owner/", "/repo", "owner/re po", "owner/repo%2f..",
    ].each do |repo|
      expect_raises(ContributorMural::ApiError, /must look like owner\/name/) do
        api.contributors(repo)
      end
    end
  end

  it "refuses an org that would change which path is requested" do
    config = config_with("members:\n  org: crystal-actions")
    api = github_api(config: config, api_base: "http://127.0.0.1:1")
    ["my-org?x=1", "my-org#z", "..", "my org", "my-org%2fadmin", ""].each do |org|
      expect_raises(ContributorMural::ApiError, /plain organization name/) do
        api.members(org)
      end
    end
  end

  it "accepts the punctuation GitHub actually allows in a repository name" do
    pages = {1 => "[#{contributor_json("alice", 1)}]"}
    with_api_server(pages) do |base, seen|
      github_api(api_base: base).contributors("my-org/some.repo_name")
      seen.first[0].should start_with("/repos/my-org/some.repo_name/contributors?")
    end
  end
end

describe "ContributorMural::GitHubApi extra sources" do
  it "fetches organization members with their group" do
    with_sources_server do |base, _seen|
      config = config_with("members:\n  org: crystal-actions\n  group: Team")
      users = github_api(config: config, api_base: base).members("crystal-actions")
      users.map(&.login).should eq(["member1"])
      users[0].group.should eq("Team")
      users[0].weight.should eq(1)
      users[0].avatar_url.should eq("https://a/m1")
    end
  end

  it "fetches stargazers" do
    with_sources_server do |base, _seen|
      config = config_with("stargazers:\n  repo: o/r")
      users = github_api(config: config, api_base: base).stargazers("o/r")
      users.map(&.login).should eq(["fan1", "fan2"])
      users[1].link.should eq("https://github.com/fan2")
    end
  end

  it "fetches sponsors with tier amounts as weights" do
    with_sources_server([SPONSOR_PAGE]) do |base, seen|
      config = config_with("sponsors:\n  login: hahwul\n  group: Sponsors")
      users = github_api(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.login).should eq(["bigfan", "smallfan"])
      users[0].weight.should eq(25)
      users[0].name.should eq("Big Fan")
      users[0].group.should eq("Sponsors")
      users[1].weight.should eq(1)
      users[1].link.should eq("https://github.com/smallfan")
      seen.count(&.starts_with?("POST /graphql")).should eq(1)
    end
  end

  it "ignores tier amounts when the sponsors block sets a weight" do
    with_sources_server([SPONSOR_PAGE]) do |base, _seen|
      config = config_with("sponsors:\n  login: hahwul\n  weight: 5")
      users = github_api(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.weight).should eq([5, 5])
    end
  end

  it "lifts members onto the configured source weight" do
    with_sources_server do |base, _seen|
      config = config_with("members:\n  org: crystal-actions\n  weight: 3")
      users = github_api(config: config, api_base: base).members("crystal-actions")
      users.map(&.weight).should eq([3])
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
      users = github_api(token: "tok", config: config, api_base: base).sponsors("hahwul")
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
      users = github_api(token: "tok", config: config, api_base: base).sponsors("hahwul")
      users.map(&.login).should eq(["a"])
      seen.count(&.starts_with?("POST /graphql")).should eq(1)
    end
  end

  it "requires a token for sponsors" do
    config = config_with("sponsors:\n  login: hahwul")
    expect_raises(ContributorMural::ApiError, /requires a `token`/) do
      github_api(config: config).sponsors("hahwul")
    end
  end

  it "surfaces GraphQL errors" do
    error_page = %({"errors":[{"message":"Something went wrong"}]})
    with_sources_server([error_page]) do |base, _seen|
      config = config_with("sponsors:\n  login: hahwul")
      expect_raises(ContributorMural::ApiError, /Something went wrong/) do
        github_api(token: "tok", config: config, api_base: base).sponsors("hahwul")
      end
    end
  end

  it "reports unknown sponsor owners" do
    missing = %({"data":{"repositoryOwner":null}})
    with_sources_server([missing]) do |base, _seen|
      config = config_with("sponsors:\n  login: nobody")
      expect_raises(ContributorMural::ApiError, /no user or organization/) do
        github_api(token: "tok", config: config, api_base: base).sponsors("nobody")
      end
    end
  end
end
