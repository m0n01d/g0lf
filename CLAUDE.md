# g0lf

## Shared conventions

Workspace-wide conventions (language choice, ReScript rules, `resq`, sub-agent orchestration, PR rules) live in the private repo [`m0n01d/claude-conventions`](https://github.com/m0n01d/claude-conventions). On the Mac they auto-load via `~/code/CLAUDE.md`; **a cloud sandbox does not see them** — fetch before starting work:

```sh
gh repo clone m0n01d/claude-conventions /tmp/conventions 2>/dev/null || git clone https://github.com/m0n01d/claude-conventions /tmp/conventions
cat /tmp/conventions/CLAUDE.md
```

If the clone fails (sandbox credentials may be scoped to this repo only), continue with this file — the critical rules for this project are inlined below.

---

A cozy infinite golf game in the spirit of Desert Golf. ReScript 12 + Vite, no framework.

```sh
npm install
npm run dev            # rescript build, then vite
npm run res:dev        # rescript watch, in a second terminal
```

## The one idea worth knowing

**Ball flight is animated by CSS, not by JavaScript.** There is no `requestAnimationFrame` anywhere
in `src/`. ReScript simulates the whole shot the moment you release the drag, compiles it into
`@keyframes`, writes them into a `<style>` element, and the browser plays it.

This works because a cubic Bézier can represent a quadratic *exactly*. Normalise one
constant-acceleration segment to run 0..1 in both time and displacement, and let

```
b = v0 * T / (p1 - p0)          # initial speed as a fraction of average speed
```

then the exact easing is `cubic-bezier(1/3, b/3, 2/3, (1+b)/3)`. The three cases you already know
fall out of it:

| motion | b | curve |
|---|---|---|
| constant speed (horizontal flight) | 1 | `cubic-bezier(.333,.333,.667,.667)` = `linear` |
| dropped from rest | 0 | `cubic-bezier(.333,0,.667,.333)` = quadratic ease-in |
| rising to apex | 2 | `cubic-bezier(.333,.667,.667,1)` = quadratic ease-out |

So a golf arc is a quadratic ease-out followed by a quadratic ease-in — not "looks like", *is*.
X and Y ride two nested elements so they can carry independent easings; one element cannot, because
a single keyframe percentage only carries one timing function.

Accuracy is verified, not assumed: across 360 simulated shots the CSS curve stays within **0.42px**
of the true parabola in flight and **0.71px** while rolling.

## Layout

| file | job |
|---|---|
| `src/Rand.res` | seeded PRNG — hole N is always the same course |
| `src/Terrain.res` | dune generation; polyline so slope is constant per span |
| `src/Physics.res` | one-shot simulation; emits the segment boundaries (`stop`s) |
| `src/Css.res` | `stop`s -> `@keyframes` with per-segment `cubic-bezier` |
| `src/Web.res` | hand-written DOM bindings (no `%raw`, no `Obj.magic`) |
| `src/Game.res` | glue: pointer input, hole progression |

`Physics.res` cuts a new segment at every acceleration change — bounce, apex, direction reversal,
slope change — because that is exactly where one Bézier stops being valid. A typical shot is ~15
stops and ~5KB of generated CSS.

## Known gap

`Game.res` is **not yet TEA**. It holds state in module-level `ref`s and mutates the DOM directly,
which is fine for a prototype but violates the Model / Msg / update / view rule in the shared
conventions. Restructure it before building the game out.

## Use `resq` when editing the `.res` files here

`resq` reads and edits ReScript structurally — prefer it over reading whole files and hand-splicing
text. Run `resq guide` for the full command reference.

```sh
resq list src/Css.res
resq get src/Css.res bezier          # decorators + doc comment included
resq refs src/Physics.res stop       # project-wide references
resq grep 'cubic-bezier' src/
```

Writes fail closed: resq refuses a file that already has parse errors, re-parses its own output, and
leaves the file byte-identical on any failure.

## Bootstrapping resq in a fresh environment

**This section exists because a cloud sandbox starts with nothing installed.** When you open this
repo on claude.ai/code (or from the phone app), you get a Linux container with only this repo — the
workspace-level `code/CLAUDE.md` is *not* present, so the instructions have to live here.

```sh
curl -fsSL https://raw.githubusercontent.com/m0n01d/resq/main/scripts/install.sh | sh
export PATH="$HOME/.cargo/bin:$PATH"
```

[`m0n01d/resq`](https://github.com/m0n01d/resq) is **public**, so this needs no credentials. The
script is idempotent and installs rustup itself if `cargo` is missing. From an existing clone,
`sh scripts/install.sh` builds from the working tree instead of refetching.

If resq cannot be installed, nothing here breaks — just edit the `.res` files directly. resq is a
convenience, not a dependency.
