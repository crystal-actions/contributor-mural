# Security Policy

## Supported versions

The `v1` tag always points at the latest 1.x release, and that is the version
that receives fixes. Older tags are left in place for reproducibility but are
not patched.

## Reporting a vulnerability

Please report privately through
[GitHub Security Advisories](https://github.com/crystal-actions/contributor-mural/security/advisories/new)
rather than a public issue. A first response usually takes a few days.

Include what the action was configured to do (a redacted config helps), what
you observed, and how to reproduce it.

## What this action touches

Worth knowing when judging whether something is a security issue:

- It runs as a Docker container action with the workspace mounted, and by
  default commits and pushes the files it generates. `no_commit: true` turns
  that off.
- It reads `avatar_url` values from your config and from the GitHub API, and
  fetches them over HTTPS. Redirects must stay on public HTTPS; internal and
  private addresses are refused, and responses are capped in size.
- Local `avatar_url` paths are resolved inside the workspace, with symlinks
  resolved before reading.
- Avatar bytes and API-provided names are embedded into a file that gets
  committed to your repository, so all of it is escaped on the way in.
- The token is used only for api.github.com requests; it is never attached to
  avatar downloads or written into the output.
