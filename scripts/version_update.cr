require "./version"

# Sets the version everywhere at once, and opens a release heading in the
# changelog for the notes to be written under.
#
# Usage: crystal run scripts/version_update.cr -- 1.2.0
#        crystal run scripts/version_update.cr        (prompts)
#
# Run this before tagging: the release workflow refuses to publish a tag that
# disagrees with VERSION.

current = Version.canonical
unless current
  STDERR.puts "cannot read the current version from #{Version::CANONICAL}"
  exit 1
end

puts "current version: #{current}"
Version::SITES.each do |site|
  found = Version.read(site)
  next if found == current
  puts "  #{site.path} reads #{found.inspect} and already disagrees; it will be set too"
end
puts

target = ARGV.first?
unless target
  print "new version (empty to cancel): "
  target = gets.try(&.strip)
end

if target.nil? || target.empty?
  puts "cancelled"
  exit 0
end

unless Version.valid?(target)
  STDERR.puts "#{target.inspect} is not a plain X.Y.Z version"
  exit 1
end

if target == current
  puts "already at #{target}; nothing to do"
  exit 0
end

Version::SITES.each do |site|
  unless File.exists?(site.path)
    STDERR.puts "  #{site.path} is missing"
    exit 1
  end
  body = File.read(site.path)
  updated = site.write.call(body, current, target)
  if updated == body
    # A no-op means the anchor did not match, which would otherwise leave one
    # file behind at the old version — the exact state this tool prevents.
    STDERR.puts "  #{site.path} was not rewritten; its version string does not look the way this script expects"
    exit 1
  end
  File.write(site.path, updated)
  puts "  #{site.path} → #{target}"
end

# Open a section for the release above the newest one, so the notes are written
# under the version that ships them rather than read as still-unreleased.
heading = Version.changelog_heading(target)

if File.exists?(Version::CHANGELOG)
  changelog = File.read(Version::CHANGELOG)
  # Anchored to the newest release heading rather than to a line count: the
  # prose above it is free to change, and a new section always belongs directly
  # on top of the previous release.
  newest = changelog.match(/^##\s+v\d+\.\d+\.\d+\s*$/m)
  if changelog.matches?(Version.changelog_heading_pattern(target))
    puts "  #{Version::CHANGELOG} already has a #{heading} section; left alone"
  elsif newest
    changelog = changelog.sub(newest[0], "#{heading}\n\n#{newest[0]}")
    File.write(Version::CHANGELOG, changelog)
    puts "  #{Version::CHANGELOG} → opened #{heading}"
  else
    STDERR.puts "  #{Version::CHANGELOG} has no release heading to file this under; add the #{heading} notes by hand"
  end
end

puts
puts "now: write the #{heading} notes, commit, then tag v#{target}"
