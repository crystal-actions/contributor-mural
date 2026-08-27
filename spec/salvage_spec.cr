require "file_utils"
require "./spec_helper"
require "./support/fake_avatar_source"

private def in_workspace(files : Hash(String, String), &)
  workspace = File.tempname("mural_salvage")
  Dir.mkdir_p(workspace)
  begin
    files.each do |path, content|
      full = File.join(workspace, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    yield workspace
  ensure
    FileUtils.rm_rf(workspace)
  end
end

private def wall(*people : {String, String}) : String
  body = people.map do |(link, uri)|
    %(  <a href="#{link}" target="_blank">\n    <title>t</title>\n) +
      %(    <image href="#{uri}" x="0" y="0" width="8" height="8"/>\n  </a>\n)
  end.join
  %(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">\n#{body}</svg>\n)
end

describe ContributorMural::AvatarSalvage do
  it "reads every face out of a previous wall" do
    files = {"wall.svg" => wall(
      {"https://github.com/alpha", "data:image/png;base64,AAAA"},
      {"https://github.com/bravo", "data:image/png;base64,BBBB"},
    )}
    in_workspace(files) do |workspace|
      found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
      found.size.should eq(2)
      found["https://github.com/alpha"].should eq("data:image/png;base64,AAAA")
      found["https://github.com/bravo"].should eq("data:image/png;base64,BBBB")
    end
  end

  # The whole point is that a face belongs to one person. A link whose avatar
  # is absent from the old file must contribute nothing rather than adopt the
  # next person's picture.
  it "never lets a link reach past the next one" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
        <a href="https://github.com/alpha" target="_blank">
          <title>alpha</title>
        </a>
        <a href="https://github.com/bravo" target="_blank">
          <title>bravo</title>
          <image href="data:image/png;base64,BBBB" x="0" y="0" width="8" height="8"/>
        </a>
      </svg>
      SVG

    in_workspace({"wall.svg" => svg}) do |workspace|
      found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
      found.keys.should eq(["https://github.com/bravo"])
    end
  end

  # Skyline draws roof and windows inside the link before the avatar, and metro
  # draws the terminus ring after it; the avatar is the first data URI either
  # way, and the styles around it must not change what is read back.
  it "takes the first data URI inside a link, whatever else the style drew" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
        <a href="https://github.com/alpha" target="_blank">
          <title>alpha</title>
          <g fill="#111"><rect x="0" y="0" width="8" height="8"/></g>
          <image href="data:image/png;base64,AAAA" x="0" y="0" width="8" height="8"/>
          <circle cx="4" cy="4" r="4" fill="none" stroke="#e5484d"/>
        </a>
      </svg>
      SVG

    in_workspace({"wall.svg" => svg}) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
        .should eq({"https://github.com/alpha" => "data:image/png;base64,AAAA"})
    end
  end

  it "reads links carrying the markup escaping they were written with" do
    files = {"wall.svg" => wall({"https://example.com/a?x=1&amp;y=2", "data:image/png;base64,AAAA"})}
    in_workspace(files) do |workspace|
      found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
      # Looked up by the escaped form, which is what the embedder builds.
      found[ContributorMural::SVG.escape("https://example.com/a?x=1&y=2")]?
        .should eq("data:image/png;base64,AAAA")
    end
  end

  it "keeps the first output's copy when several walls hold the same person" do
    files = {
      "one.svg" => wall({"https://github.com/alpha", "data:image/png;base64,ONE"}),
      "two.svg" => wall({"https://github.com/alpha", "data:image/png;base64,TWO"}),
    }
    in_workspace(files) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["one.svg", "two.svg"])
        .should eq({"https://github.com/alpha" => "data:image/png;base64,ONE"})
    end
  end

  it "ignores PNG targets and files that are not there yet" do
    in_workspace({"wall.svg" => wall({"https://github.com/alpha", "data:image/png;base64,AAAA"})}) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["wall.png", "missing.svg"]).should be_empty
    end
  end

  it "ignores a data URI that is not an image" do
    files = {"wall.svg" => wall({"https://github.com/alpha", "data:text/html;base64,AAAA"})}
    in_workspace(files) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"]).should be_empty
    end
  end

  # What comes back from here is written into an `href` verbatim, the way a
  # freshly encoded one is. That is safe only for the shape this program emits;
  # a previous wall is a file on disk — hand-edited, merge-mangled, or left
  # half-written — and one bare `&` costs the whole document, not one label.
  it "refuses a data URI carrying anything base64 cannot" do
    [
      "data:image/png;base64,AA&BB",
      "data:image/png;base64,AA<BB",
      "data:image/png;base64,AA>BB",
      "data:image/png;base64,AA\u{00a0}BB",
      "data:image/png,notbase64",
      "data:image/png;base64,AA BB",
      "data:image/png;base64,AA\nBB",
    ].each do |uri|
      in_workspace({"wall.svg" => wall({"https://github.com/alpha", uri})}) do |workspace|
        found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
        fail "salvage accepted #{uri.inspect}" unless found.empty?
      end
    end
  end

  it "accepts every content type the fetcher can produce" do
    ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml"].each do |type|
      files = {"wall.svg" => wall({"https://github.com/alpha", "data:#{type};base64,AAAA=="})}
      in_workspace(files) do |workspace|
        found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
        fail "salvage rejected #{type}" if found.empty?
      end
    end
  end

  # Byte offsets, not character offsets: one non-ASCII display name anywhere in
  # the file used to make every lookup a walk from the start of the string.
  it "reads a wall carrying non-ASCII names" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
        <a href="https://github.com/alpha" target="_blank">
          <title>한글 이름 (@alpha) · 메인테이너</title>
          <image href="data:image/png;base64,AAAA" x="0" y="0" width="8" height="8"/>
        </a>
        <a href="https://github.com/bravo" target="_blank">
          <title>另一个名字 (@bravo)</title>
          <image href="data:image/png;base64,BBBB" x="0" y="0" width="8" height="8"/>
        </a>
      </svg>
      SVG

    in_workspace({"wall.svg" => svg}) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"]).should eq({
        "https://github.com/alpha" => "data:image/png;base64,AAAA",
        "https://github.com/bravo" => "data:image/png;base64,BBBB",
      })
    end
  end

  it "treats a truncated document as a cache miss rather than an error" do
    in_workspace({"wall.svg" => %(<svg><a href="https://github.com/alpha)}) do |workspace|
      ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"]).should be_empty
    end
  end
end

# `LINK_OPEN` and `DATA_OPEN` mirror `Renderer#linked` and `Renderer#avatar`
# as literals in a different file, and only the default style was ever
# round-tripped end to end. A style that stops routing through those — or a
# `linked` rewritten with its attributes in the other order, which SVG allows
# — would silently return an empty hash and drop everyone on a flaky run.
describe "ContributorMural::AvatarSalvage against every style" do
  it "reads back every face from a wall each style actually rendered" do
    users = [
      ContributorMural::ResolvedUser.new(login: "alpha", role: "Creator"),
      ContributorMural::ResolvedUser.new(login: "bravo", name: "브라보", group: "Team"),
      ContributorMural::ResolvedUser.new(login: "charlie", link: "https://example.com/c?x=1&y=2"),
    ]

    ContributorMural::Style.each do |style|
      config = ContributorMural::Config.parse("style: #{style.to_s.downcase}\ngroups: [Team]\n")
      renderer = ContributorMural::Renderer.for(style, config)
      renderer.prepare(users)
      embedded, _skipped = ContributorMural::Embedder.new(FakeAvatarSource.new)
        .embed(users, renderer, false)
      svg = renderer.render(ContributorMural::Resolver.grouped(embedded, config))

      in_workspace({"wall.svg" => svg}) do |workspace|
        found = ContributorMural::AvatarSalvage.read(workspace, ["wall.svg"])
        fail "#{style}: salvaged #{found.size} of #{users.size}" unless found.size == users.size
        users.each do |user|
          key = ContributorMural::SVG.escape(user.link)
          fail "#{style}: lost #{user.login}" unless found[key]?
        end
      end
    end
  end
end
