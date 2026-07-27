require "base64"

module ContributorMural
  # Fetches avatars in parallel and turns them into base64 data URIs.
  # Results are cached by URL so multiple render targets reuse fetches.
  class Embedder
    # The work here is almost entirely waiting, so the ceiling is set by
    # politeness to the host rather than by anything local. Connections are kept
    # alive now, so a worker pays for one handshake instead of one per avatar —
    # which is what makes a wider pool worth having rather than just louder.
    DEFAULT_CONCURRENCY = 12

    # One avatar to fetch. The URL is resolved once on the main fiber and
    # carried along, so workers never recompute the cache key.
    private record Job, user : ResolvedUser, size : Int32, url : String

    def initialize(@source : AvatarSource, @concurrency : Int32 = DEFAULT_CONCURRENCY)
      @cache = {} of String => String | AvatarError
    end

    # Fetches everything every target will ask for in a single fan-out. A config
    # with more than one output used to fetch per target and wait out a separate
    # round of latency each time, even where the two targets wanted the same
    # faces at the same size.
    def warm(users : Array(ResolvedUser), renderers : Array(Renderer)) : Nil
      jobs = renderers.flat_map { |renderer| jobs_for(users, renderer) }
      fetch_missing(jobs.uniq!(&.url))
    end

    # Returns users with embedded avatars (input order preserved) and the
    # logins skipped due to fetch failures. Raises the first failure instead
    # when `fail_on_missing` is set.
    def embed(users : Array(ResolvedUser), renderer : Renderer,
              fail_on_missing : Bool) : {Array(EmbeddedUser), Array(String)}
      jobs = jobs_for(users, renderer)
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

    private def jobs_for(users : Array(ResolvedUser), renderer : Renderer) : Array(Job)
      users.map do |user|
        size = renderer.fetch_size(user)
        Job.new(user, size, @source.url_for(user, size))
      end
    end

    private def fetch_missing(jobs : Array(Job)) : Nil
      pending = jobs.reject { |job| @cache.has_key?(job.url) }
      return if pending.empty?

      # Every failure mode must become a value rather than an exception: one
      # escaping a worker would take that job's result with it, and a collector
      # counting replies then waits for a reply that is never coming.
      results = Concurrent.map(pending, @concurrency) do |job|
        bytes, content_type = @source.fetch(job.user, job.size)
        "data:#{content_type};base64,#{Base64.strict_encode(bytes)}".as(String | AvatarError)
      rescue ex : AvatarError
        ex.as(String | AvatarError)
      rescue ex : Exception
        AvatarError.new("unexpected failure fetching avatar (#{ex.class}): #{ex.message}")
          .as(String | AvatarError)
      end

      pending.each_with_index { |job, index| @cache[job.url] = results[index] }
    end
  end
end
