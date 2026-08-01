# Contributing

Thanks for taking a look. Issues and pull requests are both welcome — a new
style, a source, or a config option that makes a wall nicer are all fair game.

## Getting set up

You need [Crystal](https://crystal-lang.org/install/) 1.10 or newer. PNG
output additionally needs librsvg (`brew install librsvg`,
`apt install librsvg2-bin`, `apk add rsvg-convert`).

```bash
shards install
crystal spec
```

The binary doubles as a CLI, which is the fastest way to see a change:

```bash
shards build
bin/contributor-mural -c examples/showcase.yml   # regenerates examples/*.svg
```

There is a [`just`](https://just.systems) file for the tasks below, if you would rather
not remember them — `just --list` shows everything. Nothing requires it; every recipe is
the plain command it wraps.

```bash
just build          # b
just test           # t
just check          # c — format, lint, and version consistency: what CI runs
just fix            # format and apply the lint fixes it can
just golden         # re-record the renderer golden files
just examples       # regenerate the README gallery
just render         # run a config through the action image, committing nothing
```

## The README gallery

Every image in the README is generated from a committed config, and the YAML snippet
next to an image is expected to match that config verbatim — so a snippet cannot
describe something the renderer does not do. `examples/showcase.yml` produces the ten
style heroes; `examples/variants/*.yml` produce the per-option comparisons, one file per
variant (the per-style blocks are global, so `shape: circle` and `shape: square` cannot
share a run).

After a change that moves geometry or colors, regenerate both (needs network — avatars
come from github.com) and eyeball the diff:

```bash
bin/contributor-mural -c examples/showcase.yml
for f in examples/variants/*.yml; do bin/contributor-mural -c "$f"; done
```

`spec/examples_spec.cr` keeps the two in sync without rendering: it loads every example
config, checks the file it names exists, and checks the README links to it. Adding a
variant means adding a `.yml`, generating its `.svg`, and referencing it in the README —
the spec fails until all three are done. Keep variants on the small shared cast and
under ~80 KB each; the SVGs embed their avatars, so the gallery is most of the
repository's weight.

## Before opening a pull request

```bash
crystal tool format
bin/ameba src spec
crystal spec
crystal run scripts/version_check.cr
```

Or `just fix && just check && just test`.

CI runs the same, plus a Docker build and a job that runs the action through
`action.yml` the way a consumer does.

## Releasing

The action ships as a container image, so a run has to be able to say which
build it is. That only works if the version is true everywhere, and it once was
not: `VERSION` sat at `0.1.0` through two releases while the changelog still
listed the shipped styles as unreleased.

So the version lives in several files, and one command sets them all:

```bash
just vu 1.2.0     # or: crystal run scripts/version_update.cr -- 1.2.0
```

That rewrites `shard.yml`, `src/contributor_mural/version.cr`, and the README's
pinning table and banner example, then opens a `## v1.2.0` section at the top of
the changelog's release list for you to write the notes under.

`just vc` reports what every file claims and fails if they disagree, or if the
current version has no changelog section. It runs in CI, and the release
workflow independently refuses to publish a tag that disagrees with `VERSION` —
so a forgotten bump fails before it can produce a release that misreports
itself.

Review the changelog section, commit, then push the tag:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

The release workflow builds the image, republishes the release on a commit whose
`action.yml` names that version's own immutable image tag, and moves `v1.2.0`
and `v1` onto it. Nothing else needs doing by hand.

## Renderers and golden files

Each style is a `Renderer` subclass in `src/contributor_mural/renderers/`. A style
implements `fetch_size`, `block_size`, and `draw_block`; the base class takes
care of theming, group sections, and stacking.

Renderer output is pinned by golden files in `spec/fixtures/golden/`. When a
change to the geometry is intended, regenerate them and read the diff before
committing:

```bash
UPDATE_GOLDEN=1 crystal spec
git diff spec/fixtures/golden
```

Prefer a property spec over a golden where you can write one — the spiral's
"no two avatars overlap" spec is what fixes its packing constant, and it
caught a real overlap that looked fine by eye.

## A few conventions

- No runtime dependencies. The action ships as a small static binary, and
  everything so far fits in the standard library.
- Anything from the GitHub API or a user's config ends up in a file committed
  to someone's repository, so escape it and validate it.
- Config errors should name the key and say what is accepted.
