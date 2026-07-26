require "./spec_helper"
require "yaml"

# `VERSION` is what a run prints about itself and what the release workflow
# checks the git tag against, so it must not be able to drift from the
# shard's own version without something failing first.
describe ContributorMural::VERSION do
  it "matches the version in shard.yml" do
    shard = YAML.parse(File.read(Path[__DIR__] / ".." / "shard.yml"))
    shard["version"].as_s.should eq(ContributorMural::VERSION)
  end

  it "is a plain semver string, since the release tag is derived from it" do
    ContributorMural::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end
end
