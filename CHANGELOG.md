# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — for an action,
the "public API" is the config schema, the action inputs and outputs, and the
generated files.

## [Unreleased]

### Added

- `users:` entries take a `scale`, a 1–2 size multiplier for one person,
  applied after each style's own ranking. `mosaic` multiplies the tier span
  (so emphasis is exact rather than a fraction of the list, and a new
  contributor no longer re-cuts it), `spiral` and `orbit` multiply the avatar
  size and re-pack around it. `grid`, `honeycomb`, `stencil`, and `voronoi`
  have no per-user size to multiply and ignore it — a run that asks for one
  anyway says so as a workflow warning.

## [1.1.1]

### Added

- Source blocks take a `weight`, applied to every user they yield. It replaces
  the derived weight (contribution count, sponsor tier), so `users:` carries
  only the exceptions and adding a contributor needs no config change.
- `width` and `height` action outputs, describing the first generated file, so
  an embed with explicit dimensions can be corrected in the same run that
  changes the wall. A `.png` reports its rasterized size.
- `exclude` accepts `*` and `?` wildcards, matching whole logins. There are no
  `[...]` character classes, so `*[bot]` means "ends with the literal `[bot]`".
- Every run prints its version as its first line, and config errors that
  enumerate accepted values name the version that rejected them — both so a
  stale image is distinguishable from a bad config.

### Changed

- Each released ref now names its own immutable image tag: `@v1.1.0` runs
  `:v1.1.0`, and `@v1` follows releases by the git tag moving rather than by an
  image tag moving underneath it. Only `@main` tracks a floating image.
- Voronoi clip-path ids are prefixed `vcell-` instead of an abbreviation that
  `crate-ci/typos` reads as a misspelling of "for", once per cell, in a
  generated file a consumer cannot correct by hand.

### Fixed

- `VERSION` was left at `0.1.0` through both releases. It now matches the
  shard, a spec keeps the two together, and the release workflow refuses to
  publish a tag that disagrees with it.

### Documentation

- How to run the action locally through Docker, and why it cannot commit:
  `GITHUB_ACTIONS` being unset is what stops it, independently of `no_commit`.
- `include_bots: false` filters what GitHub *types* as a bot. Service accounts
  predating the GitHub Apps convention are typed `User` and need an explicit
  `exclude` entry.

## [1.1.0]

### Styles

- `voronoi` — stained glass. Avatars are clipped into irregular cells that tile
  the block edge to edge, separated by a hairline lead that lets the page show
  through. Cell area follows weight, and no cell can be squeezed to nothing
  however lopsided the weights are.
- `stencil` — the wall as a word. Avatars fill the lit pixels of `text` set in a
  built-in 5x7 face, and the pixels nobody has filled yet stay as faint dots, so
  the word completes itself as contributors arrive. Everyone gets a pixel to
  themselves before anyone shares one, and a crowd larger than the word splits
  pixels rather than dropping people.

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

### Distribution

- Runs a prebuilt multi-arch image from GHCR, so a consumer's runner starts in
  seconds instead of building Crystal on every run.

[Unreleased]: https://github.com/crystal-actions/contributor-mural/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.1.1
[1.1.0]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.1.0
[1.0.0]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.0.0
