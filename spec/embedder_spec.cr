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
    skipped.should eq(["bravo"])
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
