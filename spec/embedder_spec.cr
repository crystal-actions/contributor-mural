require "./spec_helper"
require "./support/fake_avatar_source"

private def grid_renderer(avatar_size : Int32 = 64) : ContributorMural::Renderer
  config = ContributorMural::Config.parse(<<-YAML)
    users:
      - login: placeholder
    grid:
      avatar_size: #{avatar_size}
    YAML
  ContributorMural::Renderer.for(ContributorMural::Style::Grid, config)
end

private def resolved(login : String) : ContributorMural::ResolvedUser
  ContributorMural::ResolvedUser.new(login)
end

describe ContributorMural::Embedder do
  it "embeds avatars as base64 data URIs preserving order" do
    source = FakeAvatarSource.new
    embedder = ContributorMural::Embedder.new(source)
    users = [resolved("alpha"), resolved("bravo")]

    embedded, skipped = embedder.embed(users, grid_renderer, fail_on_missing: false)

    skipped.should be_empty
    embedded.map(&.login).should eq(["alpha", "bravo"])
    expected = "data:image/png;base64,#{Base64.strict_encode("IMG:alpha:128")}"
    embedded[0].data_uri.should eq(expected)
  end

  it "caches fetches across render targets" do
    source = FakeAvatarSource.new
    embedder = ContributorMural::Embedder.new(source)
    users = [resolved("alpha"), resolved("bravo")]

    embedder.embed(users, grid_renderer, fail_on_missing: false)
    embedder.embed(users, grid_renderer, fail_on_missing: false)

    source.fetch_count.should eq(2)
  end

  it "warms every target's avatars up front, deduplicating across them" do
    source = FakeAvatarSource.new
    embedder = ContributorMural::Embedder.new(source)
    users = [resolved("alpha"), resolved("bravo")]

    # Two targets at one size and a third at another: four fetches, not six.
    embedder.warm(users, [grid_renderer(64), grid_renderer(32), grid_renderer(64)])
    source.fetch_count.should eq(4)

    # And rendering afterwards costs nothing, whichever target asks.
    embedder.embed(users, grid_renderer(64), fail_on_missing: false)
    embedder.embed(users, grid_renderer(32), fail_on_missing: false)
    source.fetch_count.should eq(4)
  end

  it "fetches again for a different size" do
    source = FakeAvatarSource.new
    embedder = ContributorMural::Embedder.new(source)
    users = [resolved("alpha")]

    embedder.embed(users, grid_renderer(64), fail_on_missing: false)
    embedder.embed(users, grid_renderer(32), fail_on_missing: false)

    source.fetch_count.should eq(2)
  end

  it "skips users whose avatar fails" do
    source = FakeAvatarSource.new(missing: ["bravo"])
    embedder = ContributorMural::Embedder.new(source)
    users = [resolved("alpha"), resolved("bravo")]

    embedded, skipped = embedder.embed(users, grid_renderer, fail_on_missing: false)

    embedded.map(&.login).should eq(["alpha"])
    skipped.map(&.login).should eq(["bravo"])
    # The reason travels with the login. Reported as "could not be fetched" on
    # its own, a refused address, a 404 and a timeout all read the same, and none
    # of them tells the reader which one they are looking at.
    skipped.first.reason.should contain("404")
  end

  it "raises on failure when fail_on_missing is set" do
    source = FakeAvatarSource.new(missing: ["bravo"])
    embedder = ContributorMural::Embedder.new(source)

    expect_raises(ContributorMural::AvatarError, /bravo/) do
      embedder.embed([resolved("bravo")], grid_renderer, fail_on_missing: true)
    end
  end

  it "handles many users with a small worker pool" do
    source = FakeAvatarSource.new
    embedder = ContributorMural::Embedder.new(source, concurrency: 3)
    users = (1..25).map { |index| resolved("user#{index}") }

    embedded, _ = embedder.embed(users, grid_renderer, fail_on_missing: false)

    embedded.size.should eq(25)
    embedded.map(&.login).should eq(users.map(&.login))
  end
end
