require "http/client"
require "uri"

module ContributorMural
  # `Retry-After` in the delta-seconds form, never longer than `cap`. The
  # HTTP-date form is legal but rare in these APIs, and a clock-skewed runner
  # would read it as a wait of hours; ignoring it falls back to the caller's own
  # backoff, which is always bounded. Shared because both the avatar fetcher and
  # the API client have to answer the same question.
  def self.retry_after(response : HTTP::Client::Response, cap : Time::Span) : Time::Span?
    seconds = response.headers["Retry-After"]?.try(&.strip.to_i?)
    return unless seconds && seconds >= 0
    Math.min(seconds.seconds, cap)
  end

  # Keep-alive HTTP connections, pooled per origin.
  #
  # Every avatar and every API page used to open a connection of its own, so a
  # mural of a few hundred faces paid for a few hundred TCP and TLS handshakes
  # against the same one or two hosts — most of the wall clock, and most of the
  # CPU, of a run that moves only a couple of megabytes. Reusing connections
  # also gives the whole program one place to set timeouts, which matters more
  # than the speed does: an unbounded read on a stalled socket used to hang the
  # job until the runner killed it, with no output and nothing in the log.
  class HTTPPool
    # Long enough for a loaded runner on a slow link, short enough that a
    # black-holed socket lands in the caller's retry loop rather than sitting
    # there. Read is the generous one: it covers a large avatar body, not just
    # the wait for the first byte.
    CONNECT_TIMEOUT = 10.seconds
    READ_TIMEOUT    = 30.seconds
    WRITE_TIMEOUT   = 10.seconds

    # A run can only reuse one idle connection per worker; past that the pool
    # would be a leak rather than a cache.
    MAX_IDLE_PER_ORIGIN = 16

    def initialize(@connect_timeout : Time::Span = CONNECT_TIMEOUT,
                   @read_timeout : Time::Span = READ_TIMEOUT,
                   @write_timeout : Time::Span = WRITE_TIMEOUT)
      @idle = {} of String => Array(HTTP::Client)
      @mutex = Mutex.new
    end

    def get(url : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      exec("GET", url, headers, nil)
    end

    # Hands the response over with its body still on the socket, so a caller
    # that cannot say in advance how much it is willing to accept can decide
    # while it reads instead of after the whole thing is in memory. The
    # response is only valid inside the block.
    #
    # The block must read the body to the end or raise. Anything left unread is
    # still queued on the connection and would be handed to whoever picks it up
    # next as the head of their own response — so raising is the way out, and
    # the connection it happened on is dropped rather than pooled.
    def get(url : String, headers : HTTP::Headers? = nil, & : HTTP::Client::Response -> T) : T forall T
      uri = URI.parse(url)
      key = origin(uri)
      client = checkout(key, uri)
      result =
        begin
          client.exec("GET", uri.request_target, headers: headers) { |response| yield response }
        rescue ex : Exception
          client.close
          raise ex
        end
      checkin(key, client)
      result
    end

    def post(url : String, headers : HTTP::Headers? = nil, body : String? = nil) : HTTP::Client::Response
      exec("POST", url, headers, body)
    end

    def close : Nil
      pooled = @mutex.synchronize do
        clients = @idle.values.flatten
        @idle.clear
        clients
      end
      pooled.each(&.close)
    end

    # The connection goes back to the pool as soon as the response body is in
    # memory, and is dropped if the exchange raised: a socket that failed
    # mid-request must never reach the next caller. `HTTP::Client` reconnects
    # by itself when a pooled connection turns out to have been closed at the
    # far end, so idle entries need no expiry of their own.
    private def exec(method : String, url : String, headers : HTTP::Headers?,
                     body : String?) : HTTP::Client::Response
      uri = URI.parse(url)
      key = origin(uri)
      client = checkout(key, uri)
      response =
        begin
          client.exec(method, uri.request_target, headers: headers, body: body)
        rescue ex : Exception
          client.close
          raise ex
        end
      checkin(key, client)
      response
    end

    private def checkout(key : String, uri : URI) : HTTP::Client
      pooled = @mutex.synchronize { @idle[key]?.try(&.pop?) }
      return pooled if pooled

      client = HTTP::Client.new(uri)
      client.connect_timeout = @connect_timeout
      client.read_timeout = @read_timeout
      client.write_timeout = @write_timeout
      client
    end

    private def checkin(key : String, client : HTTP::Client) : Nil
      surplus = @mutex.synchronize do
        bucket = @idle[key] ||= [] of HTTP::Client
        if bucket.size >= MAX_IDLE_PER_ORIGIN
          client
        else
          bucket << client
          nil
        end
      end
      surplus.try(&.close)
    end

    # Scheme, host and port decide whether a connection can be reused; the
    # default port has to be spelled out so `https://x` and `https://x:443`
    # share a bucket instead of opening two.
    private def origin(uri : URI) : String
      port = uri.port || (uri.scheme == "http" ? 80 : 443)
      "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end
end
