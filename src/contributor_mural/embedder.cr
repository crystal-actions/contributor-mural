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

    # Who kept the face the previous wall already had, because this run could
    # not fetch theirs. Accumulated here rather than returned per target: the
    # cache is what makes it a run-wide fact, and the caller reports it once.
    getter salvaged = Set(String).new

    def initialize(@source : AvatarSource, @concurrency : Int32 = DEFAULT_CONCURRENCY,
                   @salvage : Proc(Hash(String, String))? = nil)
      @cache = {} of String => String | AvatarError
    end

    # The previous wall's faces, read once on the first embed: a fetched face
    # is checked against its old copy (`#steady`), and a failed one falls back
    # to it.
    private def previous_faces : Hash(String, String)
      @previous_faces ||= @salvage.try(&.call) || {} of String => String
    end

    @previous_faces : Hash(String, String)? = nil

    # Fetches everything every target will ask for in a single fan-out. A config
    # with more than one output used to fetch per target and wait out a separate
    # round of latency each time, even where the two targets wanted the same
    # faces at the same size.
    def warm(users : Array(ResolvedUser), renderers : Array(Renderer)) : Nil
      jobs = renderers.flat_map { |renderer| jobs_for(users, renderer) }
      fetch_missing(jobs.uniq!(&.url))
    end

    # One person left out of the mural, and why. The reason travels with the
    # login because the caller is what reports it, and "could not be fetched"
    # on its own does not tell anyone whether to fix a typo, a permission, or
    # an address — the fetcher already worked that out.
    record Skipped, login : String, reason : String

    # Returns users with embedded avatars (input order preserved) and the people
    # skipped due to fetch failures. Raises the first failure instead when
    # `fail_on_missing` is set.
    def embed(users : Array(ResolvedUser), renderer : Renderer,
              fail_on_missing : Bool) : {Array(EmbeddedUser), Array(Skipped)}
      jobs = jobs_for(users, renderer)
      fetch_missing(jobs.uniq(&.url))

      embedded = [] of EmbeddedUser
      skipped = [] of Skipped
      jobs.each do |job|
        case result = @cache[job.url]
        in String
          embedded << EmbeddedUser.new(job.user, steady(job, result, users))
        in AvatarError
          # A face the last wall already carried is not a missing one, so this
          # is settled before `fail_on_missing` is consulted: that option is
          # there to stop a person quietly leaving the picture, and here nobody
          # is leaving it.
          # Only for a link nobody else on this wall carries: the face read back
          # is filed under the link, and a shared one cannot say whose it was.
          if (kept = previous_faces[SVG.escape(job.user.link)]?) &&
             users.one? { |user| user.link == job.user.link }
            embedded << EmbeddedUser.new(job.user, kept)
            @salvaged << job.user.login
          elsif fail_on_missing
            raise AvatarError.new("#{job.user.login}: #{result.message}", result.status)
          else
            skipped << Skipped.new(job.user.login, result.message || "avatar could not be fetched")
          end
        end
      end
      {embedded, skipped}
    end

    # The face the previous wall already carries, when the one just fetched
    # draws the same picture in different bytes — see `SameImage`. Committing
    # a re-encoding changes nothing anyone can see and everything git can.
    # Held to the same rule as a salvaged face: only for a link nobody else on
    # this wall carries.
    private def steady(job : Job, fetched : String, users : Array(ResolvedUser)) : String
      kept = previous_faces[SVG.escape(job.user.link)]?
      return fetched unless kept && kept != fetched
      return fetched unless users.one? { |user| user.link == job.user.link }
      SameImage.same?(kept, fetched) ? kept : fetched
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
