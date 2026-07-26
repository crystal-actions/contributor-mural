require "./version"

# Sets the version everywhere at once, and rotates the changelog's
# `## [Unreleased]` section into a release heading.
#
# Usage: crystal run scripts/version_update.cr -- 1.2.0
#        crystal run scripts/version_update.cr        (prompts)
#
# Run this before tagging: the release workflow refuses to publish a tag that
# disagrees with VERSION.

REPO = "https://github.com/crystal-actions/contributor-mural"

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

# Open a fresh Unreleased section and promote the notes that have accumulated
# under it, so the release ships with its own heading rather than leaving them
# to be read as still-unreleased.
if File.exists?(Version::CHANGELOG)
  changelog = File.read(Version::CHANGELOG)
  if changelog.matches?(/^##\s*\[#{Regex.escape(target)}\]/m)
    puts "  #{Version::CHANGELOG} already has a [#{target}] section; left alone"
  elsif changelog.includes?("## [Unreleased]")
    changelog = changelog.sub("## [Unreleased]", "## [Unreleased]\n\n## [#{target}]")
    changelog = changelog.sub(
      "[Unreleased]: #{REPO}/compare/v#{current}...HEAD",
      "[Unreleased]: #{REPO}/compare/v#{target}...HEAD\n" \
      "[#{target}]: #{REPO}/releases/tag/v#{target}"
    )
    File.write(Version::CHANGELOG, changelog)
    puts "  #{Version::CHANGELOG} → opened [#{target}]"
  else
    STDERR.puts "  #{Version::CHANGELOG} has no `## [Unreleased]` section; add the [#{target}] notes by hand"
  end
end

puts
puts "now: review the [#{target}] notes, commit, then tag v#{target}"
