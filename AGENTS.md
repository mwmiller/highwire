# AGENTS.md

## Authorship and voice

- **No LLM authorship.** Never add `Co-Authored-By`, `Generated-by`,
  `Assisted-by`, or any other LLM attribution to commits, releases, patches,
  or any other artifact in this repository (or anything it sends upstream).
  Commits are authored by Matt alone; the tooling leaves no signature.

- **Nothing in our voice without express permission.** Never open issues,
  post comments, file reviews, send email, publish releases or posts, or
  otherwise speak as Matt or HighWire in any outward-facing venue unless
  permission was given for that specific instance. Asking first is the rule;
  approval covers exactly what was described in the question and nothing
  beyond it. Local work — code, commits, drafts handed over for review — is
  fine without asking; publication is not.

- **Write for the reader, in the present tense.** Text an end user will
  see — release bodies, in-app copy, docs, download pages, error and
  status messages — describes the product as it stands, never the work
  that produced it. No changelog-of-churn ("fixed the thing that was
  broken in…", "now also handles…", "no longer…"), no diff narration, no
  internal vocabulary. Say what the feature is or does, so it reads the
  same tomorrow as today. Keep it concise, and keep every line both
  relevant and useful to the person reading it; cut anything that is
  neither.

## Releases

- **A version bump touches four files, not one.** The version lives in
  `mix.exs`, `src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json`, and
  the `highwire` package's entry in `src-tauri/Cargo.lock`. All four
  must match; the release workflow checks `mix.exs` and the two Tauri
  files against the tag and fails any leg where they disagree. Bump
  them in one commit, the same way v1.5.2 did.

- **Pushing a `v*` tag publishes.** The tag push triggers
  `.github/workflows/release.yml`, which builds all four platforms,
  notarizes the macOS dmg, and attaches the installers to a GitHub
  release for that tag. A run started by `workflow_dispatch` is a dry
  run: it builds and uploads artifacts but publishes nothing. The
  publish step is gated on the tag, so pushing `main` alone never
  releases.

- **A tag is a promise about the tree.** Build from the tag, not from
  `main` at the time — the workflow checks out the tag's commit. If the
  tree moves after the tag, the release still ships what the tag named.
