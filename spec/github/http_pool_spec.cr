require "../spec_helper"
require "socket"

# A hand-rolled HTTP server, because the thing under test is invisible to
# `HTTP::Server`: what matters is how many TCP connections were *accepted*, not
# how many requests arrived, and keep-alive is exactly the gap between the two.
private class CountingServer
  getter accepted = 0
  getter requests = 0
  getter address : String

  # `once` closes each connection after a single response, the way a server
  # that refuses keep-alive would. `mute` accepts and then never answers.
  def initialize(@once : Bool = false, @mute : Bool = false)
    @server = TCPServer.new("127.0.0.1", 0)
    @address = "http://127.0.0.1:#{@server.local_address.port}"
    spawn do
      while socket = @server.accept?
        @accepted += 1
        spawn serve(socket)
      end
    end
  end

  def close : Nil
    @server.close
  end

  private def serve(socket : TCPSocket) : Nil
    loop do
      break unless read_request(socket)
      @requests += 1
      if @mute
        # Hold the connection open and answer nothing, so the client has to be
        # the one that gives up. Closing here would send an EOF instead, which
        # is a different failure and not the one worth testing.
        socket.read_byte
        return
      end
      socket << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n"
      socket << "Connection: close\r\n" if @once
      socket << "\r\nok"
      socket.flush
      break if @once
    end
  rescue IO::Error
    # A client hanging up mid-request is normal here.
  ensure
    socket.close rescue nil
  end

  # Consumes one request line plus headers, stopping at the blank line.
  private def read_request(socket : TCPSocket) : Bool
    line = socket.gets(chomp: true)
    return false if line.nil? || line.empty?
    while (header = socket.gets(chomp: true)) && !header.empty?
    end
    true
  end
end

private def with_server(once : Bool = false, mute : Bool = false, &)
  server = CountingServer.new(once: once, mute: mute)
  begin
    yield server
  ensure
    server.close
  end
end

describe ContributorMural::HTTPPool do
  it "serves repeated requests to one origin over a single connection" do
    with_server do |server|
      pool = ContributorMural::HTTPPool.new
      5.times { pool.get("#{server.address}/avatar.png").body.should eq("ok") }
      pool.close

      server.requests.should eq(5)
      server.accepted.should eq(1)
    end
  end

  it "keeps a connection per origin rather than one for all of them" do
    with_server do |first|
      with_server do |second|
        pool = ContributorMural::HTTPPool.new
        3.times do
          pool.get("#{first.address}/a")
          pool.get("#{second.address}/b")
        end
        pool.close

        first.accepted.should eq(1)
        second.accepted.should eq(1)
        first.requests.should eq(3)
        second.requests.should eq(3)
      end
    end
  end

  it "gives concurrent fibers their own connections and reuses each of them" do
    with_server do |server|
      pool = ContributorMural::HTTPPool.new
      ContributorMural::Concurrent.map((1..12).to_a, 4) do |index|
        pool.get("#{server.address}/#{index}").body
      end.should eq(Array.new(12, "ok"))
      pool.close

      server.requests.should eq(12)
      # Four workers, so four connections at most — and fewer than twelve is the
      # whole point.
      server.accepted.should be <= 4
    end
  end

  it "recovers when the far end refuses to keep the connection alive" do
    with_server(once: true) do |server|
      pool = ContributorMural::HTTPPool.new
      3.times { pool.get("#{server.address}/a").body.should eq("ok") }
      pool.close

      server.requests.should eq(3)
      server.accepted.should eq(3)
    end
  end

  it "gives up on a server that accepts and then says nothing" do
    # Without a read timeout this is the hang that used to take a whole job
    # slot with it, no output and nothing in the log.
    with_server(mute: true) do |server|
      pool = ContributorMural::HTTPPool.new(read_timeout: 150.milliseconds)
      expect_raises(IO::TimeoutError) { pool.get("#{server.address}/slow") }
      pool.close
    end
  end

  # Keep-alive means a source holds a socket open to every host it spoke to
  # until something closes the pool. A source handed a pool leaves that to its
  # owner; one that built its own used to have no way of saying so, and the
  # connection sat there until the garbage collector happened to reach it.
  it "lets a source hand back the connections it opened" do
    with_server do |server|
      source = ContributorMural::HTTPAvatarSource.new(allow_local_targets: true)
      user = ContributorMural::ResolvedUser.new("tester", avatar_url: "#{server.address}/a.png")
      2.times { source.fetch(user, 64) }
      server.accepted.should eq(1)

      source.close
      # A closed pool has nothing to hand out, so the next fetch has to dial.
      source.fetch(user, 64)
      server.accepted.should eq(2)
      source.close
    end
  end

  it "leaves a pool it was handed for its owner to close" do
    with_server do |server|
      pool = ContributorMural::HTTPPool.new
      source = ContributorMural::HTTPAvatarSource.new(allow_local_targets: true, pool: pool)
      user = ContributorMural::ResolvedUser.new("tester", avatar_url: "#{server.address}/a.png")
      source.fetch(user, 64)
      source.close

      # Still pooled: closing it would have hung up on the pool's other users.
      pool.get("#{server.address}/b")
      server.accepted.should eq(1)
      pool.close
    end
  end

  it "does not hand a failed connection to the next caller" do
    with_server(mute: true) do |server|
      pool = ContributorMural::HTTPPool.new(read_timeout: 150.milliseconds)
      2.times { expect_raises(IO::TimeoutError) { pool.get("#{server.address}/slow") } }
      pool.close

      # A second connection means the timed-out one was dropped rather than
      # pooled: reusing it would have failed for a reason the caller cannot see.
      server.accepted.should eq(2)
    end
  end
end
