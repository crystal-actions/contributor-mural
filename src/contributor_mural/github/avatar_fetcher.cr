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

    # `allow_local_redirects` exists for specs, which redirect between
    # 127.0.0.1 ports; production keeps redirects on public https only.
    def initialize(@workspace : String = Dir.current, @backoff_base : Time::Span = 1.second,
                   @allow_local_redirects : Bool = false, pool : HTTPPool? = nil)
      @pool = pool || HTTPPool.new
      # Only the UA: an `Accept` narrower than the wild card would let an
      # avatar host we have never heard of answer 406 where it used to work.
      @headers = HTTP::Headers{"User-Agent" => USER_AGENT}
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
      MAX_REDIRECTS.times do
        response = @pool.get(url, @headers)
        case response.status_code
        when 200
          body = response.body.to_slice
          if body.size > MAX_BYTES
            raise AvatarError.new("avatar is too large: #{url} (#{body.size} bytes, limit #{MAX_BYTES})", 200)
          end
          return {body, image_content_type(response, url)}
        when 301, 302, 303, 307, 308
          location = response.headers["Location"]?
          raise AvatarError.new("redirect without Location from #{url}") unless location
          url = safe_redirect(url, location)
        when 404
          raise AvatarError.new("avatar not found (404)", 404)
        else
          raise AvatarError.new("unexpected status #{response.status_code} for #{url}",
            response.status_code, ContributorMural.retry_after(response, MAX_RETRY_AFTER))
        end
      end
      raise AvatarError.new("too many redirects for #{url}")
    end

    # Reads Content-Type from the raw header: `response.content_type` parses
    # the value and raises MIME::Error on malformed input. Unknown types fall
    # back to PNG so a sloppy host cannot inject markup into the data URI.
    private def image_content_type(response : HTTP::Client::Response, url : String) : String
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
      host = target.host
      raise AvatarError.new("avatar redirect without a host: #{target}", 400) unless host
      if internal_host?(host)
        raise AvatarError.new("refusing avatar redirect to internal address #{host}", 400)
      end
      target.to_s
    rescue ex : URI::Error | ArgumentError
      raise AvatarError.new("invalid avatar redirect target: #{ex.message}", 400)
    end

    private def internal_host?(host : String) : Bool
      return true if host.compare("localhost", case_insensitive: true).zero?
      address = Socket::IPAddress.new(host, 0) rescue nil
      return false unless address
      address.loopback? || address.private? || address.link_local? || address.unspecified?
    end
  end
end
