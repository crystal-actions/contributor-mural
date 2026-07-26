# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — for an action,
the "public API" is the config schema, the action inputs and outputs, and the
generated files.

## [Unreleased]

## [2.0.0]

The project is now **Contributor Mural**. The old name collided with an
existing organization on GitHub Marketplace, and "hall of fame" described a
wall of portraits rather than what this actually generates.

### Changed

- **Breaking** — the repository, the image, and the `uses:` reference are now
  `crystal-actions/contributor-mural`. The `v1` tags and the
  `ghcr.io/crystal-actions/hall-of-fame` image are left in place and keep
  working, so existing workflows do not break; they simply stop receiving
  updates.
- **Breaking** — the default config path is now `.github/contributor-mural.yml`
  (was `.github/hall-of-fame.yml`). Pass `config:` to keep the old path.
- **Breaking** — the default output file is now `CONTRIBUTOR_MURAL.svg` (was
  `HALL_OF_FAME.svg`), and the default commit message is now
  `chore: update contributor mural`. Set `output:` and `commit_message:` to
  keep the old values.

## [1.0.2]

### Changed

- Renamed the action to "Avatar Hall of Fame" in `action.yml` — GitHub
  Marketplace rejected "Hall of Fame" as matching an existing organization
  name. The repository, image, and `uses:` reference are unchanged.

## [1.0.1]

### Changed

- The action now runs the prebuilt image from GHCR instead of building
  Crystal on the consumer's runner, which took about a minute of every run.

## [1.0.0]

First public release.

### Styles

- `grid` — avatars in rows, as circles, rounded squares, or squares, with
  optional name and role labels.
- `honeycomb` — hex-clipped avatars in offset rows.
- `mosaic` — weight-tiered packing, so the heaviest contributors take the
  largest tiles.
- `spiral` — golden-angle phyllotaxis; rank sets both size and distance from
  the centre.
- `orbit` — the top contributor at the centre, everyone else on rings.

### Sources

- A curated `users` list, `contributors`, `members`, `stargazers`, and
  `sponsors` (tier amount becomes weight). Writing a block enables it, and
  everything merges into one mural.
- Per-user `role` labels and titled `group` sections, for the people the
  contributors API cannot see.
- `avatar_url` accepts a repository-relative file, for logos or contributors
  without a GitHub account.

### Output

- Self-contained SVG with avatars embedded as base64, so it renders inside a
  README.
- PNG via `rsvg-convert`, including light/dark pairs through `outputs[].mode`.
- Theme presets (`github`, `midnight`, `paper`, `mono`) and an `auto` mode
  that follows the viewer's dark-mode preference.
- Several files in one run through `outputs`, sharing one set of avatar
  fetches.

[Unreleased]: https://github.com/crystal-actions/contributor-mural/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/crystal-actions/contributor-mural/releases/tag/v2.0.0
[1.0.2]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.0.2
[1.0.1]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.0.1
[1.0.0]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.0.0
