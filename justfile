alias b := build
alias t := test
alias c := check
alias vc := version-check
alias vu := version-update

# List available tasks.
default:
    @just --list

# Build the binary (also the local CLI).
[group('build')]
build:
    shards install
    shards build

# Remove build artifacts and dependencies.
[group('build')]
clean:
    rm -rf bin/ lib/

# Run the tests.
[group('development')]
test:
    crystal spec

# Format and lint without changing anything — what CI runs.
[group('development')]
check: version-check
    crystal tool format --check
    @just _ameba

# Auto-format and apply the lint fixes it can.
[group('development')]
fix:
    crystal tool format
    @just _ameba --fix

# Ameba ships as a shard, so build it once and reuse it.
_ameba *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -x bin/ameba ]; then
        mkdir -p bin
        crystal build lib/ameba/bin/ameba.cr -o bin/ameba --release
    fi
    bin/ameba src spec scripts {{ args }}

# Re-record the renderer golden files, then read the diff before committing.
[group('development')]
golden:
    UPDATE_GOLDEN=1 crystal spec
    git diff --stat spec/fixtures/golden

# Regenerate the README gallery. Needs network — avatars come from github.com.
[group('documents')]
examples:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -x bin/contributor-mural ] || just build
    bin/contributor-mural -c examples/showcase.yml
    for config in examples/variants/*.yml; do
        bin/contributor-mural -c "$config"
    done

# Render a config the way the action would, without committing anything.
[group('documents')]
render config=".github/contributor-mural.yml" repo="crystal-actions/contributor-mural":
    # Nothing can be pushed from here: GITHUB_ACTIONS is unset, which is what
    # gates the commit, and INPUT_NO_COMMIT says so a second time.
    docker run --rm \
        -v "$PWD:/github/workspace" -w /github/workspace \
        -e GITHUB_REPOSITORY={{ repo }} \
        -e INPUT_CONFIG={{ config }} \
        -e INPUT_NO_COMMIT=true \
        -e INPUT_TOKEN="$(gh auth token)" \
        ghcr.io/crystal-actions/contributor-mural:v1

# Report the version every file claims, and fail if they disagree.
[group('release')]
version-check:
    @crystal run scripts/version_check.cr

# Set the version everywhere and open a changelog section; run before tagging.
[group('release')]
version-update version="":
    @crystal run scripts/version_update.cr -- {{ version }}
