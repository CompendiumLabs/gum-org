# `gum-org`

The gum.jsx packages, one git repo each, checked out side by side as **git submodules** of this
repo. Each commit here pins the exact commit of every package, so the set of checkouts that was
developed and tested together is a recoverable state, and
`git clone --recurse-submodules` reproduces the whole org. The root is also a private bun
workspace (`package.json`) over the submodules, so the packages' ordinary semver dependencies on
each other (`"@gum-jsx/core": "^1.8.0"`, ...) resolve to the sibling directories instead of npm.
`bun install` here (or in any member — bun finds the root by walking up) installs everything and
writes the single `bun.lock` here; the members keep no lockfile of their own while they live in
the workspace.

## Packages

| Directory | Package | Role |
|---|---|---|
| `gum-jsx-core` | `@gum-jsx/core` | The JSX → SVG evaluator, elements and fonts; platform-neutral |
| `gum-jsx-math` | `@gum-jsx/math` | LaTeX elements and `mathToSvg`; add-on to core (peer) |
| `gum-jsx-node` | `@gum-jsx/node` | PNG rasterizing (node-canvas), kitty output, stdin; core is a peer |
| `gum-jsx-mark` | `@gum-jsx/mark` | Markdown → terminal; core, math and node are peers |
| `gum-jsx-web` | `@gum-jsx/web` | Browser runtime: FontFace installation, font embedding, canvas rasterizing; core is a peer |
| `gum-jsx-docs` | `@gum-jsx/docs` | The docs and gallery examples plus the Claude skill; no dependencies |
| `gum-jsx-react` | `@gum-jsx/react` | React renderer and the `gum-react` CLI; core, react and react-dom are peers |
| `gum-jsx` | `gum-jsx` | Batteries included: depends on the five libraries, ships the `gum`/`gum-tex`/`gum-mark` bins and the test suite |

`gum-jsx/test/report` (the suite's render browser, private) is also a workspace member so its
`@gum-jsx/core` resolves locally.

Every package ships its TypeScript source directly (`exports` point at `src/*.ts`, as the
published `gum-jsx` always has), so there is no build step; bun runs it as is. The add-ons take
core as a **peer** dependency because their elements subclass core's and are built against a core
`Env` (the evaluation environment: element registry, bindings, fonts, theme, strict mode; see
`gum-jsx-core/CLAUDE.md`), so a host must have exactly one core; each also lists core under
`devDependencies` so it typechecks standalone. `@gum-jsx/math` is a plugin (`gum.use(math)`);
importing it has no side effects, and the batteries-included `gum-jsx` is what applies it to the
default Env. `@gum-jsx/*` and `gum-jsx` are versioned in lockstep (`1.8.0`);
`@gum-jsx/react` has its own line (`0.2.0`).

## Commands

```bash
bun install            # once, here: links the workspace and installs everything
bun run typecheck      # bun tsc --noEmit in every package
bun run test           # the gum-jsx suite (Env checks + every example in strict mode), the react and web tests
scripts/rehearse.sh    # publish to a local registry and install from it (below)
```

## Working with the submodules

Each package directory is a normal clone on its `master` branch: edit, commit and push there as
before. Afterwards this repo shows the package as `modified (new commits)`; commit that pointer
bump here to record the new combination (`git add gum-jsx-core && git commit`). Useful:

```bash
git clone --recurse-submodules <org-url>   # a fresh copy of everything
git submodule update --init                # populate the submodules of an existing clone
git submodule foreach git checkout master  # fresh clones start detached at the pinned commit
git submodule update --remote              # move every pointer to its branch tip (then commit)
git submodule foreach git status --short   # anything uncommitted anywhere
```

## Rehearsing a release

`scripts/rehearse.sh` publishes every package, in dependency order, to a throwaway
[verdaccio](https://verdaccio.org) registry on `localhost:4873`, then installs `gum-jsx` and
`@gum-jsx/react` from it into a fresh project outside the workspace and checks the bins, every
`gum-jsx/*` subpath export, `runUnitTests` on a custom group, `gum-react`, an `npm install`, and a
global `bun install -g` (redirected to a scratch directory). That exercises what the workspace
never can — the `files` whitelist, `exports` against the packed layout, bin normalization, peer
resolution and publish order — without touching npm or your real config. `KEEP=1` leaves the
scratch directory behind to poke at; `PORT=` picks another port. The registry is created fresh
each run, so re-publishing the same version after a fix is fine.

## Publishing

Publish in dependency order so each version is on npm before something depends on it:
`core`, `docs`, `math`, `node`, `mark`, `web`, then `react` and `gum-jsx`. From each directory:

```bash
npm publish    # or: bun publish (the scoped packages carry publishConfig.access = public)
```

Bump versions in lockstep, run `scripts/rehearse.sh` first, and commit the submodule pointers
here once everything is pushed. Once published, a standalone clone of any repo works with a
plain `bun install` (which then writes that repo's own lockfile) — the workspace is only a
convenience for developing them together.
