# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — for an action,
the "public API" is the config schema, the action inputs and outputs, and the
generated files.

## [Unreleased]

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

[Unreleased]: https://github.com/crystal-actions/contributor-mural/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/crystal-actions/contributor-mural/releases/tag/v1.0.0
