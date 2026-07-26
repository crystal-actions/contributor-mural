module ContributorMural
  # Kept equal to `shard.yml` by a spec, and to the git tag by the release
  # workflow, which refuses to publish a tag that disagrees with it. Both
  # guards exist because this string is what a run reports about itself — a
  # version that lies is worse than no version at all.
  VERSION = "1.1.0"
end
