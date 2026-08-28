#!/usr/bin/env bash
# Rehearse a release: publish every package to a throwaway local registry
# (verdaccio), then install them from it into a fresh project outside the
# workspace and exercise the bins, subpath exports, test runner and global
# installs. This catches what the workspace cannot: the `files` whitelist,
# `exports` against the packed layout, bin normalization, peer resolution and
# publish order. Run from the org root:
#
#   scripts/rehearse.sh            # everything
#   KEEP=1 scripts/rehearse.sh     # leave the scratch dir behind for a look
#   PORT=4874 scripts/rehearse.sh  # if 4873 is busy
#
# Needs bun, npm and curl. Nothing touches your real npm config or global bun
# install: the registry credentials go in a scratch .npmrc, and the global
# install is redirected with BUN_INSTALL_GLOBAL_DIR.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${PORT:-4873}
REG="http://localhost:$PORT/"
ORDER=(gum-jsx-core gum-jsx-docs gum-jsx-math gum-jsx-node gum-jsx-mark gum-jsx-web gum-jsx-react gum-jsx)

WORK=$(mktemp -d -t gum-rehearse.XXXXXX)
NPMRC="$WORK/.npmrc"
VPID=

say()  { printf '\033[1;34m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*"; exit 1; }

cleanup() {
    if [ -n "$VPID" ]; then kill -- -"$VPID" 2>/dev/null || kill "$VPID" 2>/dev/null || true; fi
    if [ -n "${KEEP:-}" ]; then echo "scratch dir kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- registry ---------------------------------------------------------------

say "starting verdaccio on $REG ($WORK)"
mkdir -p "$WORK/storage"
cat > "$WORK/config.yaml" <<YAML
storage: ./storage
auth:
  htpasswd:
    file: ./htpasswd
    max_users: 1000
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
packages:
  '@gum-jsx/*':
    access: \$all
    publish: \$authenticated
  'gum-jsx':
    access: \$all
    publish: \$authenticated
  '**':
    access: \$all
    proxy: npmjs
log: { type: file, path: $WORK/verdaccio.log, level: warn }
YAML
# setsid puts the registry in its own process group so cleanup can kill bunx
# and the verdaccio it spawns together
setsid bunx verdaccio@6 --config "$WORK/config.yaml" --listen "$PORT" > "$WORK/verdaccio.out" 2>&1 &
VPID=$!
for _ in $(seq 1 90); do curl -sf "$REG-/ping" > /dev/null && break; sleep 1; done
curl -sf "$REG-/ping" > /dev/null || fail "verdaccio did not come up (see $WORK/verdaccio.out)"

TOKEN=$(curl -sf -X PUT "$REG-/user/org.couchdb.user:rehearse" \
    -H 'content-type: application/json' -d '{"name":"rehearse","password":"rehearse"}' \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(!j.token){console.error(s);process.exit(1)}process.stdout.write(j.token)})')
[ -n "$TOKEN" ] || fail "could not create a registry user"
printf 'registry=%s\n//localhost:%s/:_authToken=%s\n' "$REG" "$PORT" "$TOKEN" > "$NPMRC"

# --- publish ----------------------------------------------------------------

for pkg in "${ORDER[@]}"; do
    say "publish $pkg"
    (cd "$ROOT/$pkg" && npm publish --access public --registry "$REG" --userconfig "$NPMRC" 2>&1 \
        | grep -E '^\+|warn publish|ERR!' || true)
done
for pkg in "${ORDER[@]}"; do
    name=$(cd "$ROOT/$pkg" && node -p 'require("./package.json").name')
    npm view "$name" version --registry "$REG" --userconfig "$NPMRC" > /dev/null 2>&1 \
        || fail "$name is not on the registry after publish"
done

# --- install into a fresh project ------------------------------------------

APP="$WORK/app"
mkdir -p "$APP/ex/code"
cd "$APP"
printf '{ "name": "rehearse-app", "private": true, "type": "module" }\n' > package.json
cp "$NPMRC" .npmrc

say "bun add gum-jsx @gum-jsx/react (from the local registry)"
bun add gum-jsx @gum-jsx/react react react-dom --registry "$REG" > bun-add.log 2>&1 || { cat bun-add.log; fail "bun add"; }
for name in core docs math node mark react; do
    [ -e "node_modules/@gum-jsx/$name" ] || fail "@gum-jsx/$name not installed"
done
for bin in gum gum-tex gum-mark gum-react; do
    [ -e "node_modules/.bin/$bin" ] || fail "bin $bin not linked"
done

say "bins"
echo '<Rectangle rounded fill={blue} />' | bunx gum -f svg | grep -q '<svg' || fail "gum -f svg"
bunx gum-tex '\sqrt{2}' -f svg | grep -q '<svg' || fail "gum-tex"
printf 'hi $y=x^2$\n' | bunx gum-mark | grep -q $'\e_G' || fail "gum-mark (no kitty image in output)"

say "library imports (every gum-jsx subpath)"
cat > use.ts <<'TS'
import { Circle, blue } from 'gum-jsx'
import { evaluateGum } from 'gum-jsx/eval'
import { mathToSvg } from 'gum-jsx/math'
import { mathToPng } from 'gum-jsx/render'
import { getDocs } from 'gum-jsx/meta'
import { runTests } from 'gum-jsx/test'
import { displayMarkdown } from 'gum-jsx/mark'
import { rasterizeSvg } from '@gum-jsx/node'
const check = (name: string, ok: boolean) => { if (!ok) { console.error(`FAIL: ${name}`); process.exit(1) } }
check('Circle', typeof Circle == 'function' && typeof blue == 'string')
check('evaluateGum + Latex', evaluateGum('<Latex>{"\\\\frac{a}{b}"}</Latex>', { size: 200 }).svg().includes('<svg'))
check('mathToSvg', mathToSvg('x^2').includes('<svg'))
check('mathToPng', (await mathToPng('x^2')).length > 100)
check('getDocs', Object.keys(getDocs().tags).length > 10)
check('rasterizeSvg', (await rasterizeSvg(evaluateGum('<Circle />').svg())).length > 100)
check('displayMarkdown/runTests', typeof displayMarkdown == 'function' && typeof runTests == 'function')
TS
bun use.ts || fail "library imports"

say "runTests on a custom group"
echo '<Square fill={red} />' > ex/code/sq.jsx
bun -e "import { runTests } from 'gum-jsx/test'; process.exit(runTests({ groups: [{ name: 'ex', dir: 'ex/code' }] }).failed)" > /dev/null 2>&1 \
    || fail "runTests"

say "gum-react CLI"
cat > comp.tsx <<'TSX'
import { GUM } from '@gum-jsx/react'
const { Frame, Circle, Latex } = GUM
export default function Scene() {
  return <Frame margin={0.1}><Circle fill="blue" /><Latex>{"x^2"}</Latex></Frame>
}
TSX
bunx gum-react comp.tsx -s 300 | grep -q '<svg' || fail "gum-react"

say "@gum-jsx/web from the registry (not a gum-jsx dependency, so installed on its own)"
cd "$APP"
bun add @gum-jsx/web --registry "$REG" > bun-add-web.log 2>&1 || { cat bun-add-web.log; fail "bun add @gum-jsx/web"; }
cat > web.ts <<'TS'
import { loadFonts } from '@gum-jsx/core/fonts'
import { fontCss, embedFonts, installFontFaces } from '@gum-jsx/web'
import { evaluateGum } from '@gum-jsx/core/eval'
await loadFonts()
installFontFaces()
const svg = embedFonts(evaluateGum('<Text>hi</Text>', { size: 100 })).svg()
if (!svg.includes('@font-face') || fontCss().length < 1000) { console.error('FAIL: web'); process.exit(1) }
TS
bun web.ts || fail "@gum-jsx/web"

say "npm install (resolution only)"
mkdir -p "$WORK/app-npm" && cd "$WORK/app-npm"
printf '{ "name": "rehearse-app-npm", "private": true }\n' > package.json
cp "$NPMRC" .npmrc
npm install gum-jsx @gum-jsx/react react react-dom --ignore-scripts --registry "$REG" --userconfig "$NPMRC" > npm.log 2>&1 \
    || { cat npm.log; fail "npm install"; }
[ -e node_modules/.bin/gum ] || fail "npm did not link the gum bin"

say "global bun install (isolated global dir)"
export BUN_INSTALL_GLOBAL_DIR="$WORK/global" BUN_INSTALL_BIN="$WORK/global/bin"
bun install -g gum-jsx @gum-jsx/react --registry "$REG" > "$WORK/global.log" 2>&1 || { cat "$WORK/global.log"; fail "bun install -g"; }
echo '<Circle />' | "$WORK/global/bin/gum" -f svg | grep -q '<svg' || fail "global gum"
"$WORK/global/bin/gum-react" "$APP/comp.tsx" -s 100 | grep -q '<svg' || fail "global gum-react"

say "all rehearsal checks passed"
