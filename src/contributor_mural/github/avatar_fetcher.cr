require "http/client"
require "socket"
require "uri"

module ContributorMural
  class AvatarError < Exception
    getter status : Int32?

    # What the server asked us to wait, when it said so. Carried on the error
    # because the decision to retry is made a level up from the response.
    getter retry_after : Time::Span?

    def initialize(message : String, @status : Int32? = nil, @retry_after : Time::Span? = nil)
      super(message)
    end
  end

  # Seam for avatar retrieval so specs can inject a fake.
  abstract class AvatarSource
    # Stable identity of the request, used as the cache/dedupe key.
    abstract def url_for(user : ResolvedUser, size : Int32) : String

    # Returns image bytes and content type for the avatar at `size` px.
    abstract def fetch(user : ResolvedUser, size : Int32) : {Bytes, String}
  end

  # Fetches avatars over HTTP, or straight from the workspace when
  # `avatar_url` is a plain relative path (org logos, folks without a GitHub
  # account). `HTTP::Client` does not follow redirects and
  # `github.com/<login>.png` answers with a 301, so redirects are handled here.
  class HTTPAvatarSource < AvatarSource
    MAX_REDIRECTS = 5
    MAX_ATTEMPTS  = 3
    # Avatars are small; anything larger is a misconfigured URL, and the bytes
    # end up base64-encoded inside a committed file.
    MAX_BYTES = 8 * 1024 * 1024

    # Statuses worth another attempt. 429 and 408 are the reason this is a list
    # rather than `>= 500`: a throttled or timed-out request used to count as a
    # permanent failure, and the mural quietly lost that person's face — the one
    # outcome nobody notices until the picture is already committed.
    RETRYABLE_STATUSES = {408, 425, 429, 500, 502, 503, 504}

    # A server may name any delay it likes; we still have a job to finish.
    MAX_RETRY_AFTER = 30.seconds

    # Sent on every request: an unidentified client is the first thing a CDN
    # throttles, and being throttled here costs us faces.
    USER_AGENT = "contributor-mural/#{VERSION}"

    CONTENT_TYPES = {
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif"  => "image/gif",
      ".webp" => "image/webp",
      ".svg"  => "image/svg+xml",
    }

    ALLOWED_CONTENT_TYPES = CONTENT_TYPES.values.to_set

    # Both flags exist for specs, which fetch from and redirect between
    # 127.0.0.1 ports; production keeps redirects on public https only and
    # refuses to fetch from the runner's own network at all.
    # `allow_local_redirects` implies `allow_local_targets`, since a spec that
    # follows a local redirect had to reach the local server first.
    def initialize(@workspace : String = Dir.current, @backoff_base : Time::Span = 1.second,
                   @allow_local_redirects : Bool = false, pool : HTTPPool? = nil,
                   allow_local_targets : Bool? = nil)
      @allow_local_targets = allow_local_targets.nil? ? @allow_local_redirects : allow_local_targets
      # A pool handed in belongs to the caller and outlives this source; one
      # built here does not, and has to be given back — see `#close`.
      @owns_pool = pool.nil?
      @pool = pool || HTTPPool.new
      # Answered once per host: a mural of a few thousand faces asks about the
      # same two or three, and the answer involves the resolver.
      @internal_hosts = {} of String => Bool
      # Only the UA: an `Accept` narrower than the wild card would let an
      # avatar host we have never heard of answer 406 where it used to work.
      @headers = HTTP::Headers{"User-Agent" => USER_AGENT}
    end

    # Hands back the connections this source opened.
    #
    # Keep-alive means a source holds a socket open to every host it spoke to
    # until something says otherwise, and a source that built its own pool had
    # no way to say it. The connection then sat there until the garbage
    # collector happened to reach it — invisible to the action, which owns one
    # pool for the whole run and closes it, and unbounded for anything that
    # builds a source per repository in a loop.
    #
    # A no-op when the pool was handed in: closing someone else's pool hangs up
    # on whoever else is still using it.
    def close : Nil
      @pool.close if @owns_pool
    end

    def self.local_path?(avatar_url : String) : Bool
      !avatar_url.matches?(%r{\Ahttps?://}i)
    end

    def url_for(user : ResolvedUser, size : Int32) : String
      if base = user.avatar_url
        return "file:#{base}" if self.class.local_path?(base)
        separator = base.includes?('?') ? '&' : '?'
        "#{base}#{separator}s=#{size}"
      else
        "https://github.com/#{URI.encode_path_segment(user.login)}.png?size=#{size}"
      end
    end

    def fetch(user : ResolvedUser, size : Int32) : {Bytes, String}
      if (base = user.avatar_url) && self.class.local_path?(base)
        read_local(base)
      else
        get_with_retries(url_for(user, size))
      end
    end

    # Reads a workspace-relative avatar. The config validator rejects `..` and
    # absolute paths lexically; realpath closes the symlink escape.
    private def read_local(path : String) : {Bytes, String}
      content_type = CONTENT_TYPES[File.extname(path).downcase]?
      unless content_type
        raise AvatarError.new("unsupported local avatar type: #{path} (use #{CONTENT_TYPES.keys.join("/")})")
      end
      full = File.join(@workspace, path)
      raise AvatarError.new("local avatar not found: #{path}", 404) unless File.file?(full)

      begin
        resolved = File.realpath(full)
        root = File.realpath(@workspace)
      rescue ex : File::Error
        raise AvatarError.new("local avatar could not be read: #{path} (#{ex.message})")
      end
      unless resolved == root || resolved.starts_with?("#{root}#{File::SEPARATOR}")
        raise AvatarError.new("local avatar escapes the repository: #{path}")
      end

      size = File.size(resolved)
      if size > MAX_BYTES
        raise AvatarError.new("local avatar is too large: #{path} (#{size} bytes, limit #{MAX_BYTES})")
      end

      begin
        {File.read(resolved).to_slice, content_type}
      rescue ex : File::Error
        raise AvatarError.new("local avatar could not be read: #{path} (#{ex.message})")
      end
    end

    private def get_with_retries(url : String) : {Bytes, String}
      attempt = 0
      loop do
        attempt += 1
        wait = nil.as(Time::Span?)
        begin
          return get_following_redirects(url)
        rescue ex : AvatarError
          status = ex.status
          # A 404 or a refused redirect will read the same way next time.
          raise ex if status && !RETRYABLE_STATUSES.includes?(status)
          raise ex if attempt >= MAX_ATTEMPTS
          wait = ex.retry_after
        rescue ex : Exception
          # Socket, TLS, URI and MIME failures all land here; only AvatarError
          # may escape this method so the worker fiber never dies.
          raise AvatarError.new("could not fetch avatar: #{ex.message}") if attempt >= MAX_ATTEMPTS
        end
        # A throttled host tells us when to come back; guessing over the top of
        # that answer is how a run earns a longer ban.
        sleep(wait || @backoff_base * (2 ** (attempt - 1)) * (1.0 + rand * 0.25))
      end
    end

    private def get_following_redirects(url : String) : {Bytes, String}
      refuse_internal_target(url)
      MAX_REDIRECTS.times do
        outcome = @pool.get(url, @headers) do |response|
          # Read before looking at the status. The body has to come off the
          # socket whatever it says, or the connection cannot be handed to the
          # next avatar — and it is only safe to take at all with a limit.
          body = read_capped(response.body_io, url)
          case response.status_code
          when 200
            {body, image_content_type(response)}
          when 301, 302, 303, 307, 308
            response.headers["Location"]? ||
              raise AvatarError.new("redirect without Location from #{url}")
          when 404
            raise AvatarError.new("avatar not found (404)", 404)
          else
            raise AvatarError.new("unexpected status #{response.status_code} for #{url}",
              response.status_code, ContributorMural.retry_after(response, MAX_RETRY_AFTER))
          end
        end
        return outcome unless outcome.is_a?(String)
        url = safe_redirect(url, outcome)
      end
      raise AvatarError.new("too many redirects for #{url}")
    end

    # Takes at most `MAX_BYTES`, and stops the moment there is more.
    #
    # The limit used to be applied to a body already sitting in memory, which
    # means it only ever rejected the ones small enough to have fit — an
    # `avatar_url` answering with a gigabyte took the runner down with it
    # before anything got to look at the size. On a workflow that builds a
    # mural from a pull request, that address is the contributor's to pick.
    #
    # One byte over the limit is enough to know; reading it also leaves the
    # socket short of its own body, which is why this raises rather than
    # returns, and why the connection is dropped instead of pooled.
    private def read_capped(body : IO, url : String) : Bytes
      buffer = IO::Memory.new
      if IO.copy(body, buffer, MAX_BYTES + 1) > MAX_BYTES
        raise AvatarError.new("avatar is too large: #{url} (limit #{MAX_BYTES} bytes)", 200)
      end
      buffer.to_slice
    end

    # Reads Content-Type from the raw header: `response.content_type` parses
    # the value and raises MIME::Error on malformed input. Unknown types fall
    # back to PNG so a sloppy host cannot inject markup into the data URI.
    private def image_content_type(response : HTTP::Client::Response) : String
      raw = response.headers["Content-Type"]?.try(&.split(';').first.strip.downcase)
      return "image/png" unless raw
      ALLOWED_CONTENT_TYPES.includes?(raw) ? raw : "image/png"
    end

    # Redirects must stay on https and off the internal network: the response
    # body is base64-embedded into a file committed to a public repository.
    private def safe_redirect(from : String, location : String) : String
      target = URI.parse(from).resolve(location)
      return target.to_s if @allow_local_redirects
      unless target.scheme == "https"
        raise AvatarError.new("refusing non-https avatar redirect to #{target}", 400)
      end
      host = target.hostname
      raise AvatarError.new("avatar redirect without a host: #{target}", 400) unless host
      if internal_host?(host)
        raise AvatarError.new("refusing avatar redirect to internal address #{host}", 400)
      end
      target.to_s
    rescue ex : URI::Error | ArgumentError
      raise AvatarError.new("invalid avatar redirect target: #{ex.message}", 400)
    end

    # The first URL is the one nobody was vetting. `safe_redirect` only ever saw
    # the second request onward, so an `avatar_url` written straight at the
    # runner's own network — a cloud metadata endpoint, a service on the host —
    # was fetched, labelled `image/png` whatever came back, and base64-embedded
    # into a file the run then commits. On a workflow that builds a mural from a
    # pull request, the address is the contributor's to choose.
    private def refuse_internal_target(url : String) : Nil
      return if @allow_local_targets
      # `hostname`, not `host`: the latter keeps the brackets around an IPv6
      # literal, and `[::1]` is not an address any of this recognises.
      host = URI.parse(url).hostname
      # No host means nothing to reach: a workspace-relative avatar never gets
      # here, it is read off disk.
      return unless host
      return unless internal_host?(host)
      raise AvatarError.new("refusing to fetch an avatar from #{host} — " \
                            "it is an address on the runner's own network", 400)
    rescue ex : URI::Error
      raise AvatarError.new("invalid avatar URL #{url.inspect}: #{ex.message}", 400)
    end

    private def internal_host?(host : String) : Bool
      cached = @internal_hosts[host]?
      return cached unless cached.nil?
      verdict = resolves_internal?(host)
      @internal_hosts[host] = verdict
      verdict
    end

    # Judged on the addresses the name actually answers with, not on how it is
    # spelled. Testing the literal alone let a hostname pointed at an internal
    # address walk past — as did the decimal form of one, since `2130706433` is
    # not a literal to `Socket::IPAddress` but is 127.0.0.1 to the resolver.
    #
    # This raises the bar rather than sealing it: the connection resolves the
    # name again for itself, so a name that answers differently each time can
    # still get through. Closing that means connecting to an address already
    # vetted and carrying the `Host` header along by hand.
    private def resolves_internal?(host : String) : Bool
      return true if host.compare("localhost", case_insensitive: true).zero?
      if literal = (Socket::IPAddress.new(host, 0) rescue nil)
        return internal_address?(literal)
      end

      addresses =
        begin
          Socket::Addrinfo.resolve(host, 80, type: Socket::Type::STREAM)
        rescue Socket::Error
          # A name that does not resolve is not a verdict to make here; let the
          # request fail where the error can say what actually happened.
          return false
        end
      addresses.any? { |info| internal_address?(info.ip_address) }
    end

    private def internal_address?(address : Socket::IPAddress) : Bool
      address.loopback? || address.private? || address.link_local? || address.unspecified?
    end
  end
end
