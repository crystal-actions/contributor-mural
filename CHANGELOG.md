# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — for
an action, the "public API" is the config schema, the action inputs and outputs,
and the generated files.

## Unreleased

### Fixed

- The `svg_path` output is emitted again. It is declared in `action.yml` and
  documented as the alias kept for workflows written before `outputs` existed,
  but nothing ever wrote it — those workflows have been reading the empty
  string. It carries the same value as `paths`.
- A user returned by more than one API source keeps a real display name instead
  of a login. The contributors API reports no name, so the login stood in for
  one, and first-wins then shadowed the name a `sponsors` entry did carry.
- Two outputs naming the same file through different spellings (`./wall.svg`
  and `wall.svg`) are rejected as duplicates. The run used to render both, leave
  only the second on disk, and still report two paths for it.

### Changed

- Pagination stops fanning out past what `max` can use. A window is requested
  before any of it is read, so a `max` that ended two pages in used to buy four
  and discard two — up to three wasted requests per source, against a quota of
  sixty an hour without a token. Results are unchanged: a page whose contents
  are filtered away still sends the walk round again.
- `voronoi` no longer clips every cell against every other seed. A seed too far
  off to reach what is left of a cell is ruled out by a bound the weight clamp
  already guarantees, and the clipper works out of two buffers instead of
  allocating the polygon afresh for each of those cuts. A wall of 4000 faces
  renders in half the time, one of 600 in a third.
- `mosaic` packing starts at the first row that still has a free cell instead of
  rescanning the filled rows from the top for every avatar. A wall of 4000 faces
  packs in an eighth of the time.

Both are exact: the same seeds cut the same cells and every avatar lands in the
same square, so a regenerated mural is byte for byte the file it was before.

## v1.1.2

### Added

- `users:` entries take a `scale`, a 1–2 size multiplier applied after each
  style's own ranking. `mosaic` multiplies the tier span, `spiral` and `orbit`
  multiply the avatar size and re-pack. `grid`, `honeycomb`, `stencil`, and
  `voronoi` have no per-user size and warn when asked for one.

### Changed

- HTTP connections are pooled and kept alive per host, so a mural of a few
  hundred faces no longer pays for a few hundred TLS handshakes. Generated files
  are byte-for-byte unchanged.
- Work that only waits now overlaps: sources fetch together, pages after the
  first fan out off GitHub's `Link` header, `.png` outputs convert side by side,
  and a multi-output config fetches each target's avatars once. A collection
  still stops at the configured `max`, so this costs no extra API requests.

### Fixed

- Every HTTP request carries connect, read, and write timeouts. A stalled socket
  used to hang the job until the runner killed it, with nothing in the log.
- A throttled avatar (`429`, or a timeout) is retried instead of dropped from the
  mural. Both clients honor `Retry-After`, capped at 30 seconds; an exhausted
  hourly quota still fails fast.
- Retry backoff is jittered on the API client, so sources running side by side
  cannot back off in lockstep and retrip the same limit.

### Documentation

- The examples invite readers to add their own login and open a PR.

## v1.1.1

### Added

- Source blocks take a `weight`, applied to every user they yield, so `users:`
  carries only the exceptions and adding a contributor needs no config change.
- `width` and `height` action outputs, describing the first generated file, so an
  embed with explicit dimensions can be corrected in the same run.
- `exclude` accepts `*` and `?` wildcards, matching whole logins. No `[...]`
  classes, so `*[bot]` means "ends with the literal `[bot]`".
- Every run prints its version first, and config errors that enumerate accepted
  values name the version that rejected them.

### Changed

- Each released ref names its own immutable image tag: `@v1.1.0` runs `:v1.1.0`,
  and `@v1` follows releases by the git tag moving. Only `@main` floats.
- Voronoi clip-path ids are prefixed `vcell-`, which `crate-ci/typos` no longer
  reads as a misspelling once per cell.

### Fixed

- `VERSION` was left at `0.1.0` through both releases. It now matches the shard,
  a spec keeps the two together, and the release workflow refuses a mismatched
  tag.

### Documentation

- How to run the action locally through Docker, and why it cannot commit: an
  unset `GITHUB_ACTIONS` stops it, independently of `no_commit`.
- `include_bots: false` filters what GitHub *types* as a bot. Older service
  accounts are typed `User` and need an explicit `exclude` entry.

## v1.1.0

### Styles

- `voronoi` — stained glass. Avatars clipped into irregular cells that tile the
  block edge to edge, separated by a hairline lead. Cell area follows weight, and
  no cell can be squeezed to nothing.
- `stencil` — the wall as a word. Avatars fill the lit pixels of `text` in a
  built-in 5x7 face, unfilled pixels stay as faint dots, and a crowd larger than
  the word splits pixels rather than dropping people.

## v1.0.0

First public release.

### Styles

- `grid` — avatars in rows, as circles, rounded squares, or squares, with
  optional name and role labels.
- `honeycomb` — hex-clipped avatars in offset rows.
- `mosaic` — weight-tiered packing, so the heaviest contributors take the largest
  tiles.
- `spiral` — golden-angle phyllotaxis; rank sets both size and distance from the
  centre.
- `orbit` — the top contributor at the centre, everyone else on rings.

### Sources

- A curated `users` list, `contributors`, `members`, `stargazers`, and `sponsors`
  (tier amount becomes weight). Writing a block enables it, and everything merges
  into one mural.
- Per-user `role` labels and titled `group` sections.
- `avatar_url` accepts a repository-relative file, for logos or contributors
  without a GitHub account.

### Output

- Self-contained SVG with avatars embedded as base64, so it renders inside a
  README.
- PNG via `rsvg-convert`, including light/dark pairs through `outputs[].mode`.
- Theme presets (`github`, `midnight`, `paper`, `mono`) and an `auto` mode that
  follows the viewer's dark-mode preference.
- Several files in one run through `outputs`, sharing one set of avatar fetches.

### Distribution

- Runs a prebuilt multi-arch image from GHCR, so a consumer's runner starts in
  seconds instead of building Crystal on every run.
  
