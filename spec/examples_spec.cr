require "file_utils"
require "./spec_helper"
require "./support/fake_avatar_source"

# The README is a gallery: every image is generated from a committed config, and
# every image URL points at raw.githubusercontent.com. Both are easy to break by
# renaming a file, and neither is covered by the renderer specs — so check them
# here, without rendering anything or touching the network.
private REPO_ROOT = Path[__DIR__].parent

private def repo_file(*parts : String) : String
  (REPO_ROOT / Path[*parts]).to_s
end

# The YAML blocks in the README that are mural configs rather than workflow
# snippets, as {first line, body} so a failure can name where to look.
private def readme_configs(readme : String) : Array({Int32, String})
  blocks = [] of {Int32, String}
  body = nil.as(String?)
  start = 0
  readme.each_line.each_with_index do |line, index|
    if collected = body
      if line.starts_with?("```")
        blocks << {start, collected}
        body = nil
      else
        body = "#{collected}#{line}\n"
      end
    elsif line.starts_with?("```yaml") || line.starts_with?("```yml")
      body = ""
      start = index + 2
    end
  end

  workflow = /^\s*(uses|runs-on|steps|jobs|permissions):/m
  mural = /^(style|output|outputs|users|groups|contributors|members|stargazers|sponsors|exclude|sort|limit|fail_on_missing|grid|honeycomb|mosaic|spiral|orbit|voronoi|stencil|constellation|skyline|metro|pebble|theme|png):/m
  blocks.select { |(_line, text)| text.matches?(mural) && !text.matches?(workflow) }
end

describe "examples" do
  it "renders every committed config to a file the config names" do
    configs = Dir[repo_file("examples", "**", "*.yml")].sort!
    configs.should_not be_empty

    configs.each do |path|
      config = ContributorMural::Config.load(path)
      paths = config.outputs.try(&.map(&.path)) || [config.output]
      paths.each do |output|
        relative = Path[path].relative_to(REPO_ROOT)
        File.exists?(repo_file(output)).should be_true,
          "#{relative} declares #{output}, which is missing — regenerate it with `bin/contributor-mural -c #{relative}`"
      end
    end
  end

  it "links only to files that exist from the README" do
    readme = File.read(repo_file("README.md"))
    prefix = "https://raw.githubusercontent.com/crystal-actions/contributor-mural/main/"
    linked = readme.scan(/#{Regex.escape(prefix)}([\w.\/-]+)/).map(&.[1]).uniq!
    linked.should_not be_empty

    missing = linked.reject { |path| File.exists?(repo_file(path)) }
    missing.should be_empty
  end

  it "shows every generated example somewhere in the README" do
    readme = File.read(repo_file("README.md"))
    svgs = Dir[repo_file("examples", "**", "*.svg")]
      .map { |path| Path[path].relative_to(REPO_ROOT).to_s }
      .sort!

    unused = svgs.reject { |path| readme.includes?(path) }
    unused.should be_empty
  end

  # Existence only says the file was committed once. These are the configs the
  # README points readers at and the ones `bin/contributor-mural -c …` is
  # documented to regenerate, so a change that makes one of them fail to render
  # should not wait for someone to try it by hand. No network: the avatars are
  # faked, and each render goes to a throwaway workspace rather than over the
  # committed art.
  it "still renders every committed config" do
    configs = Dir[repo_file("examples", "**", "*.yml")].sort!
    configs.should_not be_empty

    workspace = File.tempname("mural_examples")
    Dir.mkdir_p(workspace)
    annotations = IO::Memory.new
    ContributorMural::Annotations.io = annotations
    begin
      configs.each do |path|
        relative = Path[path].relative_to(REPO_ROOT)
        config = ContributorMural::Config.load(path)
        runner = ContributorMural::Runner.new(config, FakeAvatarSource.new, workspace)
        runner.run.should eq(0), "#{relative} did not render:\n#{annotations}"

        runner.written_paths.each do |written|
          svg = File.read(File.join(workspace, written))
          svg.should start_with("<svg "), "#{relative} wrote something that is not an SVG"
          svg.should contain("<image "), "#{relative} rendered without a single avatar"
        end
      end
    ensure
      ContributorMural::Annotations.io = STDOUT
      FileUtils.rm_rf(workspace)
    end
  end

  # Config parsing is strict, so a key the schema no longer has does not degrade
  # gracefully in a pasted config — it rejects the file outright. The reference
  # page went out with three `group`s its own `groups` list did not name, and the
  # typo guard the list exists to be is what turned that into a hard error.
  it "shows only configs that the parser and the validator accept" do
    configs = readme_configs(File.read(repo_file("README.md")))
    configs.size.should be > 15

    configs.each do |line, body|
      where = "README.md:#{line}"
      begin
        ContributorMural::Config.parse(body)
      rescue ex : ContributorMural::ConfigError
        fail "#{where} does not parse: #{ex.message}\n#{body}"
      end

      # Most blocks are style fragments, which is right in prose but is not a
      # runnable config on its own; lend those a source so what is left to fail
      # is a value the page recommends and the validator refuses.
      sourced = body.matches?(/^(users|contributors|members|stargazers|sponsors):/m)
      runnable = sourced ? body : "#{body}users:\n  - login: octocat\n"
      begin
        ContributorMural::Config.parse(runnable).validate!
      rescue ex : ContributorMural::ConfigError
        fail "#{where} does not validate: #{ex.message}\n#{runnable}"
      end
    end
  end
end
