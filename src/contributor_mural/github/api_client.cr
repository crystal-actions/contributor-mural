require "http/client"
require "json"
require "uri"

module ContributorMural
  class ApiError < Exception
  end

  # Server-side failures worth another attempt; carries the same message the
  # caller would otherwise see, plus the delay the server named if it named one.
  private class RetryableApiError < ApiError
    getter retry_after : Time::Span?

    def initialize(message : String, @retry_after : Time::Span? = nil)
      super(message)
    end
  end

  # Seam for GitHub-backed user sources so specs can inject a fake.
  abstract class GitHubSource
    abstract def contributors(repo : String) : Array(ResolvedUser)
    abstract def members(org : String) : Array(ResolvedUser)
    abstract def stargazers(repo : String) : Array(ResolvedUser)
    abstract def sponsors(login : String) : Array(ResolvedUser)
  end

  # Fetches users from the GitHub REST and GraphQL APIs. Contribution counts
  # and sponsor tier amounts become user weights.
  class GitHubApi < GitHubSource
    PER_PAGE     = 100
    MAX_ATTEMPTS =   3

    # How many pages of one collection may be in flight together. Enough that a
    # thousand stargazers stop being ten round trips in a row, low enough to
    # stay clear of the secondary rate limit that punishes bursts.
    PAGE_WINDOW = 4

    # A secondary rate limit names its own delay; anything longer than this is
    # better spent failing with a message someone can act on.
    MAX_RETRY_AFTER = 30.seconds

    REPO_PATTERN = %r{\A[^/\s]+/[^/\s]+\z}

    def initialize(@token : String? = nil, @config : Config = Config.empty,
                   @api_base : String = "https://api.github.com",
                   @backoff_base : Time::Span = 1.second,
                   pool : HTTPPool? = nil)
      @pool = pool || HTTPPool.new
    end

    def contributors(repo : String) : Array(ResolvedUser)
      options = @config.contributors || ContributorsConfig.new
      validate_repo(repo, "contributors")

      users = [] of ResolvedUser
      each_page("/repos/#{repo}/contributors#{options.include_anonymous? ? "?anon=1" : ""}",
        "repository #{repo}", ContributorDTO, wanted: -> { options.max - users.size }) do |dto|
        next unless user = contributor_to_user(dto, repo, options)
        users << user
        return users if users.size >= options.max
      end
      users
    end

    def members(org : String) : Array(ResolvedUser)
      options = @config.members
      return [] of ResolvedUser unless options

      users = [] of ResolvedUser
      each_page("/orgs/#{org}/members", "organization #{org}", AccountDTO,
        wanted: -> { options.max - users.size }) do |dto|
        users << account_to_user(dto, options.group, options.weight)
        return users if users.size >= options.max
      end
      users
    end

    def stargazers(repo : String) : Array(ResolvedUser)
      options = @config.stargazers
      return [] of ResolvedUser unless options
      validate_repo(repo, "stargazers")

      users = [] of ResolvedUser
      each_page("/repos/#{repo}/stargazers", "repository #{repo}", AccountDTO,
        wanted: -> { options.max - users.size }) do |dto|
        users << account_to_user(dto, options.group, options.weight)
        return users if users.size >= options.max
      end
      users
    end

    def sponsors(login : String) : Array(ResolvedUser)
      options = @config.sponsors
      return [] of ResolvedUser unless options
      if @token.nil? || @token.try(&.empty?)
        raise ApiError.new("fetching sponsors requires a `token` (GraphQL API)")
      end

      users = [] of ResolvedUser
      cursor = nil.as(String?)
      loop do
        connection = sponsors_page(login, Math.min(PER_PAGE, options.max), cursor)
        connection["nodes"].as_a.each do |node|
          next unless user = sponsor_from(node, options.group, options.weight)
          users << user
          return users if users.size >= options.max
        end
        break unless connection.dig?("pageInfo", "hasNextPage").try(&.as_bool?)
        next_cursor = connection.dig?("pageInfo", "endCursor").try(&.as_s?)
        # Without a fresh cursor the same page would be requested forever.
        break if next_cursor.nil? || next_cursor == cursor
        cursor = next_cursor
      end
      users
    end

    # A private or deleted sponsor comes back as an explicit null entity.
    private def sponsor_from(node : JSON::Any, group : String?, weight : Int32?) : ResolvedUser?
      entity = node["sponsorEntity"]?.try(&.as_h?)
      return unless entity
      sponsor_login = entity["login"]?.try(&.as_s?)
      return unless sponsor_login

      monthly = node.dig?("tier", "monthlyPriceInDollars").try(&.as_i?) || 1
      ResolvedUser.new(
        login: sponsor_login,
        name: entity["name"]?.try(&.as_s?) || sponsor_login,
        link: entity["url"]?.try(&.as_s?) || "https://github.com/#{sponsor_login}",
        avatar_url: entity["avatarUrl"]?.try(&.as_s?),
        weight: weight || Math.max(monthly, 1),
        group: group,
      )
    end

    SPONSORS_QUERY = <<-GRAPHQL
      query($login: String!, $first: Int!, $after: String) {
        repositoryOwner(login: $login) {
          ... on User {
            sponsorshipsAsMaintainer(first: $first, after: $after, activeOnly: true) {
              pageInfo { hasNextPage endCursor }
              nodes {
                tier { monthlyPriceInDollars }
                sponsorEntity {
                  ... on User { login name avatarUrl url }
                  ... on Organization { login name avatarUrl url }
                }
              }
            }
          }
          ... on Organization {
            sponsorshipsAsMaintainer(first: $first, after: $after, activeOnly: true) {
              pageInfo { hasNextPage endCursor }
              nodes {
                tier { monthlyPriceInDollars }
                sponsorEntity {
                  ... on User { login name avatarUrl url }
                  ... on Organization { login name avatarUrl url }
                }
              }
            }
          }
        }
      }
      GRAPHQL

    private struct ContributorDTO
      include JSON::Serializable

      getter login : String? = nil
      getter avatar_url : String? = nil
      getter html_url : String? = nil
      getter contributions : Int32 = 0
      getter type : String = "User"
      getter name : String? = nil
      getter email : String? = nil
    end

    private struct AccountDTO
      include JSON::Serializable

      getter login : String
      getter avatar_url : String? = nil
      getter html_url : String? = nil
    end

    private def validate_repo(repo : String, section : String) : Nil
      return if repo.matches?(REPO_PATTERN)
      raise ApiError.new("#{section} `repo` must look like owner/name, got: #{repo.inspect}")
    end

    # Walks a paginated collection, yielding every item in order.
    #
    # Page 1 comes back with a `Link` header naming the last page, which turns
    # the rest of the walk from "request, wait, decide, repeat" into a few
    # bounded fan-outs — a thousand stargazers used to be ten round trips in
    # series. Without a `Link` header there is nothing to plan from, so that
    # path stays sequential.
    #
    # `wanted` reports how many more items the caller can still use, and is what
    # keeps the fan-out from outrunning the config. Fetching a window is a bet
    # placed before any of it is read, so a `max` two pages past the last one
    # already in hand used to cost four requests and throw two away — against a
    # quota of 60 an hour without a token, that is the difference between a run
    # that finishes and one that does not. The estimate is deliberately an upper
    # bound: a filtered-out bot means a page yields fewer items than it holds,
    # and a window that comes up short simply goes round again.
    private def each_page(path : String, context : String, dto : T.class,
                          wanted : Proc(Int32)? = nil, & : T ->) : Nil forall T
      separator = path.includes?('?') ? '&' : '?'
      page_url = ->(page : Int32) do
        "#{@api_base}#{path}#{separator}per_page=#{PER_PAGE}&page=#{page}"
      end

      response = get_response(page_url.call(1), context)
      first = parse_page(response.body, context, dto)
      return unless first
      first.each { |item| yield item }
      return if first.size < PER_PAGE

      last = last_page(response)
      page = 2
      while last.nil? || page <= last
        window = last ? Math.min(window_size(wanted), last - page + 1) : 1
        return if window < 1
        bodies = Concurrent.map((page...page + window).to_a, PAGE_WINDOW) do |number|
          get_response(page_url.call(number), context).body
        end
        bodies.each do |body|
          batch = parse_page(body, context, dto)
          return unless batch
          batch.each { |item| yield item }
          return if batch.size < PER_PAGE
        end
        page += window
      end
    end

    # Pages to request together: the full window unless the caller has said it
    # needs fewer items than that many pages could hold.
    private def window_size(wanted : Proc(Int32)?) : Int32
      return PAGE_WINDOW unless wanted
      still = wanted.call
      return 0 if still <= 0
      Math.min(PAGE_WINDOW, (still + PER_PAGE - 1) // PER_PAGE)
    end

    # `nil` means the collection is over: an empty body (a 204, say) is not a
    # JSON array, and neither is a proxy's HTML error page — that one has to
    # surface as an API error rather than a raw parse exception.
    private def parse_page(body : String, context : String, dto : T.class) : Array(T)? forall T
      return if body.blank?
      begin
        Array(T).from_json(body)
      rescue ex : JSON::ParseException
        raise ApiError.new("#{context}: unexpected response from GitHub (#{ex.message})")
      end
    end

    # `Link: <https://api.github.com/...?page=7>; rel="last", <...>; rel="next"`.
    # Splitting on commas is safe for the URLs GitHub puts in here.
    private def last_page(response : HTTP::Client::Response) : Int32?
      link = response.headers["Link"]?
      return unless link
      link.split(',').each do |part|
        next unless part.includes?(%(rel="last"))
        if match = part.match(/[?&]page=(\d+)/)
          number = match[1].to_i?
          return number if number && number > 1
        end
      end
      nil
    end

    private def sponsors_page(login : String, first : Int32, cursor : String?) : JSON::Any
      payload = {
        query:     SPONSORS_QUERY,
        variables: {login: login, first: first, after: cursor},
      }.to_json
      body = with_retries("GraphQL") do
        response = @pool.post("#{@api_base}/graphql", headers: headers, body: payload)
        check_status(response, "sponsors of #{login}")
        response.body
      end
      json =
        begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          raise ApiError.new("sponsors: unexpected response from GitHub (#{ex.message})")
        end
      if errors = json["errors"]?
        first_message = errors.as_a?.try(&.first?).try(&.["message"]?).try(&.as_s?)
        raise ApiError.new("GitHub GraphQL error: #{first_message || errors.to_json}")
      end
      owner = json.dig?("data", "repositoryOwner")
      if owner.nil? || owner.raw.nil?
        raise ApiError.new("sponsors: no user or organization named #{login.inspect}")
      end
      connection = owner.dig?("sponsorshipsAsMaintainer")
      raise ApiError.new("sponsors: #{login} does not expose sponsorships") unless connection
      connection
    end

    # The response, not just the body: page 1 of a collection carries the `Link`
    # header the pagination plan is built from.
    private def get_response(url : String, context : String) : HTTP::Client::Response
      with_retries(context) do
        response = @pool.get(url, headers)
        check_status(response, context)
        response
      end
    end

    private def with_retries(context : String, & : -> T) : T forall T
      attempt = 0
      loop do
        attempt += 1
        wait = nil.as(Time::Span?)
        begin
          return yield
        rescue ex : RetryableApiError
          raise ApiError.new(ex.message || "GitHub API error") if attempt >= MAX_ATTEMPTS
          wait = ex.retry_after
        rescue ex : ApiError
          raise ex
        rescue ex : Exception
          # Socket, TLS and other transport failures; only ApiError leaves
          # this method so callers have one error type to handle.
          raise ApiError.new("network error talking to GitHub (#{context}): #{ex.message}") if attempt >= MAX_ATTEMPTS
        end
        # Jitter earns its keep now that several sources and several pages are in
        # flight together: without it they back off in lockstep and hit the same
        # limit again at the same instant.
        sleep(wait || @backoff_base * (2 ** (attempt - 1)) * (1.0 + rand * 0.25))
      end
    end

    private def check_status(response : HTTP::Client::Response, context : String) : Nil
      case response.status_code
      when 200, 204
        nil
      when 401
        raise ApiError.new("GitHub API rejected the token (401) — check the `token` input")
      when 403, 429
        # Two different failures share these codes. An exhausted hourly quota
        # will still be exhausted in a second, so it stays fatal with a message
        # that says what to do about it. A secondary (burst) limit names its own
        # delay and clears on its own — waiting it out is the whole fix.
        raise rate_limit_error(response) if response.headers["x-ratelimit-remaining"]? == "0"
        if wait = ContributorMural.retry_after(response, MAX_RETRY_AFTER)
          raise RetryableApiError.new(
            "GitHub API asked for a #{wait.total_seconds.round.to_i}s pause (#{context})", wait)
        end
        raise rate_limit_error(response)
      when 404
        raise ApiError.new("#{context}: not found or not accessible (pass a token with access?)")
      when 500..599
        # GitHub 5xx is usually transient, and the avatar fetcher already
        # retries these; keep both clients on the same policy.
        raise RetryableApiError.new("GitHub API returned #{response.status_code} for #{context}")
      else
        raise ApiError.new("GitHub API returned #{response.status_code} for #{context}")
      end
    end

    private def rate_limit_error(response : HTTP::Client::Response) : ApiError
      if response.headers["x-ratelimit-remaining"]? == "0"
        reset = response.headers["x-ratelimit-reset"]?.try(&.to_i64?)
        at = reset ? " (resets at #{Time.unix(reset).to_rfc3339})" : ""
        ApiError.new("GitHub API rate limit exceeded#{at} — pass a `token` to raise the limit")
      else
        ApiError.new("GitHub API denied the request (#{response.status_code})")
      end
    end

    private def contributor_to_user(dto : ContributorDTO, repo : String,
                                    options : ContributorsConfig) : ResolvedUser?
      weight = options.weight || Math.max(dto.contributions, 1)
      if login = dto.login
        return if bot?(dto) && !options.include_bots?
        ResolvedUser.new(
          login: login,
          link: dto.html_url || "https://github.com/#{login}",
          avatar_url: dto.avatar_url,
          weight: weight,
          group: options.group,
        )
      else
        return unless options.include_anonymous?
        seed = dto.name || dto.email || "anonymous"
        ResolvedUser.new(
          login: seed,
          link: "https://github.com/#{repo}/commits?author=#{URI.encode_www_form(dto.email || seed)}",
          avatar_url: "https://github.com/identicons/#{URI.encode_path_segment(seed)}.png",
          weight: weight,
          group: options.group,
        )
      end
    end

    private def account_to_user(dto : AccountDTO, group : String?, weight : Int32?) : ResolvedUser
      ResolvedUser.new(
        login: dto.login,
        link: dto.html_url || "https://github.com/#{dto.login}",
        avatar_url: dto.avatar_url,
        weight: weight || 1,
        group: group,
      )
    end

    private def bot?(dto : ContributorDTO) : Bool
      dto.type == "Bot" || !!dto.login.try(&.ends_with?("[bot]"))
    end

    private def headers : HTTP::Headers
      result = HTTP::Headers{
        "Accept"               => "application/vnd.github+json",
        "User-Agent"           => "contributor-mural/#{VERSION}",
        "X-GitHub-Api-Version" => "2022-11-28",
      }
      if token = @token
        result["Authorization"] = "Bearer #{token}" unless token.empty?
      end
      result
    end
  end
end
