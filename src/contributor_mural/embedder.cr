require "base64"

module ContributorMural
  # Fetches avatars in parallel and turns them into base64 data URIs.
  # Results are cached by URL so multiple render targets reuse fetches.
  class Embedder
    # One avatar to fetch. The URL is resolved once on the main fiber and
    # carried along, so workers never recompute the cache key.
    private record Job, user : ResolvedUser, size : Int32, url : String

    def initialize(@source : AvatarSource, @concurrency : Int32 = 8)
      @cache = {} of String => String | AvatarError
    end

    # Returns users with embedded avatars (input order preserved) and the
    # logins skipped due to fetch failures. Raises the first failure instead
    # when `fail_on_missing` is set.
    def embed(users : Array(ResolvedUser), renderer : Renderer,
              fail_on_missing : Bool) : {Array(EmbeddedUser), Array(String)}
      jobs = users.map do |user|
        size = renderer.fetch_size(user)
        Job.new(user, size, @source.url_for(user, size))
      end
      fetch_missing(jobs.uniq(&.url))

      embedded = [] of EmbeddedUser
      skipped = [] of String
      jobs.each do |job|
        case result = @cache[job.url]
        in String
          embedded << EmbeddedUser.new(job.user, result)
        in AvatarError
          raise AvatarError.new("#{job.user.login}: #{result.message}", result.status) if fail_on_missing
          skipped << job.user.login
        end
      end
      {embedded, skipped}
    end

    private def fetch_missing(jobs : Array(Job)) : Nil
      pending = jobs.reject { |job| @cache.has_key?(job.url) }
      return if pending.empty?

      channel = Channel({String, String | AvatarError}).new
      queue = Channel(Job).new(pending.size)
      pending.each { |job| queue.send(job) }
      queue.close

      Math.min(@concurrency, pending.size).times do
        spawn do
          while job = queue.receive?
            # Every failure mode must become a value on the channel: an
            # exception escaping this fiber kills only the fiber, and the
            # collector below would then block on `receive` forever.
            result = begin
              bytes, content_type = @source.fetch(job.user, job.size)
              "data:#{content_type};base64,#{Base64.strict_encode(bytes)}".as(String | AvatarError)
            rescue ex : AvatarError
              ex.as(String | AvatarError)
            rescue ex : Exception
              AvatarError.new("unexpected failure fetching avatar (#{ex.class}): #{ex.message}")
                .as(String | AvatarError)
            end
            channel.send({job.url, result})
          end
        end
      end

      pending.size.times do
        url, result = channel.receive
        @cache[url] = result
      end
    end
  end
end
