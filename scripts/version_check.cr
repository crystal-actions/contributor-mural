require "./version"

# Reports the version every file claims, and fails when they disagree.
#
# `spec/version_spec.cr` covers the shard/VERSION pair on every `crystal spec`
# for the tightest possible loop; this is the full sweep, including the README
# and the changelog, and is what CI and `just vc` run.

found = Version::SITES.map { |site| {site, Version.read(site)} }
width = Version::SITES.max_of(&.path.size)

found.each do |site, version|
  puts "  #{site.path.ljust(width)}  #{version || "not found"}"
end

versions = found.compact_map { |_site, version| version }.uniq!

if versions.empty?
  STDERR.puts "\nno version found in any file"
  exit 1
end

failed = false

if versions.size > 1
  STDERR.puts "\nversions disagree: #{versions.join(", ")}"
  missing = found.select { |_site, version| version.nil? }.map { |site, _| site.path }
  STDERR.puts "could not read: #{missing.join(", ")}" unless missing.empty?
  STDERR.puts "run `just vu` to set them all at once"
  failed = true
end

current = Version.canonical
if current.nil?
  STDERR.puts "\ncannot read #{Version::CANONICAL}, which is the version everything else follows"
  failed = true
else
  unless Version.valid?(current)
    STDERR.puts "\n#{current.inspect} is not a plain X.Y.Z version, and the release tag is derived from it"
    failed = true
  end

  unless Version.changelog_documents?(current)
    STDERR.puts "\n#{Version::CHANGELOG} has no `#{Version.changelog_heading(current)}` section"
    STDERR.puts "a version bumped everywhere but the changelog is how 1.1.0 shipped its notes as unreleased"
    failed = true
  end
end

exit 1 if failed

puts "\nall files agree on #{versions.first}, and it is documented in #{Version::CHANGELOG}"
