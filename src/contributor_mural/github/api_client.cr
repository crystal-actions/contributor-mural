require "http/client"
require "json"
require "uri"

module ContributorMural
  class ApiError < Exception
  end

  # Server-side failures worth another attempt; carries the same message the
  # caller would otherwise see.
  private class RetryableApiError < ApiError
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

    REPO_PATTERN = %r{\A[^/\s]+/[^/\s]+\z}

    def initialize(@token : String? = nil, @config : Config = Config.empty,
                   @api_base : String = "https://api.github.com",
                   @backoff_base : Time::Span = 1.second)
    end

    def contributors(repo : String) : Array(ResolvedUser)
      options = @config.contributors || ContributorsConfig.new
      validate_repo(repo, "contributors")

      users = [] of ResolvedUser
      each_page("/repos/#{repo}/contributors#{options.include_anonymous? ? "?anon=1" : ""}",
        "repository #{repo}", ContributorDTO) do |dto|
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
      each_page("/orgs/#{org}/members", "organization #{org}", AccountDTO) do |dto|
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
      each_page("/repos/#{repo}/stargazers", "repository #{repo}", AccountDTO) do |dto|
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

    private def each_page(path : String, context : String, dto : T.class, & : T ->) : Nil forall T
      separator = path.includes?('?') ? '&' : '?'
      page = 1
      loop do
        url = "#{@api_base}#{path}#{separator}per_page=#{PER_PAGE}&page=#{page}"
        body = get_body(url, context)
        # A 204 (or a proxy's HTML error page) is not a JSON array; surface
        # that as an API error rather than a raw parse exception.
        break if body.strip.empty?
        batch =
          begin
            Array(T).from_json(body)
          rescue ex : JSON::ParseException
            raise ApiError.new("#{context}: unexpected response from GitHub (#{ex.message})")
          end
        batch.each { |item| yield item }
        break if batch.size < PER_PAGE
        page += 1
      end
    end

    private def sponsors_page(login : String, first : Int32, cursor : String?) : JSON::Any
      payload = {
        query:     SPONSORS_QUERY,
        variables: {login: login, first: first, after: cursor},
      }.to_json
      body = with_retries("GraphQL") do
        response = HTTP::Client.post("#{@api_base}/graphql", headers: headers, body: payload)
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

    private def get_body(url : String, context : String) : String
      with_retries(context) do
        response = HTTP::Client.get(url, headers: headers)
        check_status(response, context)
        response.body
      end
    end

    private def with_retries(context : String, & : -> String) : String
      attempt = 0
      loop do
        attempt += 1
        begin
          return yield
        rescue ex : RetryableApiError
          raise ApiError.new(ex.message || "GitHub API error") if attempt >= MAX_ATTEMPTS
        rescue ex : ApiError
          raise ex
        rescue ex : Exception
          # Socket, TLS and other transport failures; only ApiError leaves
          # this method so callers have one error type to handle.
          raise ApiError.new("network error talking to GitHub (#{context}): #{ex.message}") if attempt >= MAX_ATTEMPTS
        end
        sleep @backoff_base * (2 ** (attempt - 1))
      end
    end

    private def check_status(response : HTTP::Client::Response, context : String) : Nil
      case response.status_code
      when 200, 204
        nil
      when 401
        raise ApiError.new("GitHub API rejected the token (401) — check the `token` input")
      when 403, 429
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
