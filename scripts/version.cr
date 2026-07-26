require "yaml"

# Shared by `scripts/version_check.cr` and `scripts/version_update.cr`.
#
# Every place the project states its own version, and how to read and rewrite
# each one. Kept in one file so a new location cannot be added to the checker
# without the updater learning about it too — the failure mode this whole
# thing exists to prevent is a version that is true in some files and stale in
# others.
module Version
  # Written by hand and read by everything else.
  CANONICAL = "src/contributor_mural/version.cr"

  record Site,
    path : String,
    # Nil when the file has no version yet, which is a mismatch, not a crash.
    read : Proc(String, String?),
    # Takes the file contents and the old and new versions, returns the
    # rewritten contents. Takes the old version so a rewrite can be anchored
    # to the exact string it is replacing rather than to a loose pattern.
    write : Proc(String, String, String, String)

  SITES = [
    Site.new(
      path: CANONICAL,
      read: ->(body : String) { body.match(/VERSION\s*=\s*"([^"]+)"/).try(&.[](1)) },
      write: ->(body : String, _old : String, new : String) {
        body.gsub(/VERSION\s*=\s*"[^"]+"/, %(VERSION = "#{new}"))
      },
    ),
    Site.new(
      path: "shard.yml",
      read: ->(body : String) {
        YAML.parse(body)["version"]?.try(&.as_s?)
      },
      write: ->(body : String, _old : String, new : String) {
        body.sub(/^version:\s*\S+/m, "version: #{new}")
      },
    ),
    # The README states the current version in its pinning table and in the
    # example of the startup banner. Those are claims about the release people
    # are being told to pin, so they go stale the moment the version moves.
    #
    # Anchored to "v<old>" rather than a bare version: the string also has to
    # survive appearing inside an image tag (`:v1.1.0`) and a ref (`@v1.1.0`).
    Site.new(
      path: "README.md",
      read: ->(body : String) { body.match(/^contributor-mural v(\S+)$/m).try(&.[](1)) },
      write: ->(body : String, old : String, new : String) {
        body.gsub("v#{old}", "v#{new}")
      },
    ),
  ]

  # Deliberately NOT a site: the changelog mentions unrelated versions —
  # `keepachangelog.com/en/1.1.0/` among them — so it is never rewritten by
  # substitution. What is checked is that the current version has a release
  # heading, which is what catches a release whose notes were left sitting
  # under "Unreleased" (exactly how 1.1.0 shipped).
  CHANGELOG = "CHANGELOG.md"

  def self.read(site : Site) : String?
    return unless File.exists?(site.path)
    site.read.call(File.read(site.path))
  rescue
    nil
  end

  def self.canonical : String?
    site = SITES.find { |candidate| candidate.path == CANONICAL }
    site ? read(site) : nil
  end

  def self.changelog_documents?(version : String) : Bool
    return false unless File.exists?(CHANGELOG)
    File.read(CHANGELOG).matches?(/^##\s*\[#{Regex.escape(version)}\]/m)
  end

  def self.valid?(version : String) : Bool
    version.matches?(/\A\d+\.\d+\.\d+\z/)
  end
end
