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

## The README gallery

Every image in the README is generated from a committed config, and the YAML snippet
next to an image is expected to match that config verbatim — so a snippet cannot
describe something the renderer does not do. `examples/showcase.yml` produces the seven
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
```

CI runs the same three, plus a Docker build and a job that runs the action
through `action.yml` the way a consumer does.

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
