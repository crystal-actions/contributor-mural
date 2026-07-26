require "./spec_helper"

# The README is a gallery: every image is generated from a committed config, and
# every image URL points at raw.githubusercontent.com. Both are easy to break by
# renaming a file, and neither is covered by the renderer specs — so check them
# here, without rendering anything or touching the network.
private REPO_ROOT = Path[__DIR__].parent

private def repo_file(*parts : String) : String
  (REPO_ROOT / Path[*parts]).to_s
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
end
