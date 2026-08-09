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

Accuracy is verified, not assumed: across 360 simulated shots the CSS curve stays within **0.67px**
of the true parabola in flight and **1.0px** while rolling. A typical shot is ~13 keyframe stops and
~6KB of generated CSS.

## Layout

| file | job |
|---|---|
| `src/Rand.res` | seeded PRNG — hole N is always the same course |
| `src/Terrain.res` | dune generation; polyline so slope is constant per span |
| `src/Physics.res` | one-shot simulation; emits the segment boundaries (`stop`s) |
| `src/Css.res` | `stop`s -> `@keyframes` with per-segment `cubic-bezier` |
| `src/Web.res` | hand-written DOM bindings (no `%raw`, no `Obj.magic`) |
| `src/Model.res` | `model`, `msg`, `cmd`, `init` — the whole of the state |
| `src/Update.res` | `update: (model, msg) => (model, cmd)` — pure, no DOM |
| `src/View.res` | the only module that writes to the DOM |
| `src/Game.res` | runtime: dispatch loop, command interpreter, subscriptions |

`Physics.res` cuts a new segment at every acceleration change — bounce, apex, direction reversal,
slope change — because that is exactly where one Bézier stops being valid.

`Css.thin` caps a shot at 160 keyframes. It exists because a ball creeping along a crease on broken
ground once produced 10,143 stops and 3.6MB of CSS for a single shot. Flight stops carry the arc and
are always kept; only surplus rolling stops are subsampled. In practice 0.3% of shots touch it.

## Difficulty

`Terrain.difficulty` ramps 0..1 over the first ~34 holes, then holds. It drives:

| lever | hole 1 | hole 35+ |
|---|---|---|
| dune amplitude | 0.07 × height | 0.17 × height |
| octave falloff (`dunes ~detail`) | 1.65 | 1.25 — choppier, harder to read a bounce |
| tee-to-cup carry | ~470px | ~660px |
| flat landing pad at the cup | 34px core | 18px core |
| feature pool | plain dunes only | ridge / gully / mesa / bowl |

Each hole gets one shaped feature: a `Ridge` or `Gully` to carry between tee and cup, or a `Plateau`
or `Bowl` at the cup itself. The pool widens as the round goes on.

Two invariants keep it playable, and both are load-bearing:

- **`Terrain.limitSlope` caps any span at slope 1.3.** Stacked octaves otherwise reach slope 10 —
  an 84° wall the ball just ricochets off. It runs between two `flatten` passes because the two
  fight each other: the limiter can tilt a small pad, and a pad's blend against tall neighbouring
  terrain is itself steep. Two rounds converge.
- **`Physics` rests a ball wedged in a notch**, regardless of how steep the faces are. Terrain can
  now be steeper than `rollMu`, so without this the ball creeps in the crease until the flight cap.

Verified by playing holes 1–60 with a greedy solver: every hole is finishable, and the number of
aims (out of ~2500 sampled) that hole out in one shot falls from 104 to 44 — the target window
narrows by well over half while never closing.

`preview.html` renders a grid of holes for eyeballing the curve; it is dev-only and is not part of
the production build.

## Keeping score

The run persists to `localStorage` under `g0lf.run.v1`, so closing the app and reopening resumes
where you were. `Score.res` holds it: hole, total strokes, aces, best hole, and the trajectory
toggle.

- **`avg`** — total strokes over completed holes — is the score that means anything here. There is
  no par and no end, so a total on its own only tells you how long you have played.
- The save is written **only when a hole is sunk**, so there is no mid-hole state to restore and no
  question about quitting to dodge a bad hole — you replay that hole from the tee.
- Encoding is a version-tagged pipe-delimited line (`1|hole|total|aces|best|bestHole|cheat`) rather
  than JSON. It is six integers, and the version means a future format change discards old saves
  instead of misreading them. `decode` returns an option; anything unparseable starts a fresh run.
- `Score.encode`/`decode`/`record` are pure. The storage call itself is a `cmd` (`Persist` /
  `Forget`) interpreted by `Game.res`, so `update` stays testable.
- **`new run` needs two presses** within 4s. Wiping a long run on a stray tap would be miserable,
  and the armed state lives in the model with an `After(4000, ResetDisarmed)` command.

`Web.read`/`write`/`forget` wrap the storage calls in `try`, because Safari throws on `setItem` in
private browsing rather than failing quietly.

## Deploying

Live at **https://m0n01d.github.io/g0lf/**, served from the `gh-pages` branch.

`vite.config.js` sets `base: "/g0lf/"` because project Pages serve under the repo name. To publish
a new build:

```sh
npm run build
git worktree add --detach /tmp/ghp && cd /tmp/ghp
git checkout gh-pages
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -r /path/to/g0lf/dist/. . && touch .nojekyll
git add -A && git commit -m "Publish built site" && git push
```

`docs/github-pages-workflow.yml` automates exactly this on every push. It is **not** active — it
lives in `docs/` because a cloud sandbox's token lacks the `workflow` OAuth scope and cannot write
`.github/workflows/`. To turn it on, from a local checkout with normal credentials:

```sh
mkdir -p .github/workflows
git mv docs/github-pages-workflow.yml .github/workflows/deploy.yml
git commit -m "Enable Pages deploy workflow" && git push
```

It uses `actions/configure-pages` with `enablement: true`, so it will repoint Pages at the Actions
source by itself — after which the `gh-pages` branch is no longer used and can be deleted.

## The trajectory toggle

The `◎ trajectory` chip in the HUD is a cheat: while aiming it draws the ball's whole predicted
path, bounces and roll included, and turns the end marker red when that drag would hole out.

It is honest by construction rather than by tuning. `showTrail` calls the same `Physics.simulate`
the real shot calls, then reads positions back with `Physics.sample`, which rebuilds each segment
from the same constant acceleration the CSS keyframes encode. Preview and shot cannot drift because
they are the same computation — measured, the predicted resting point lands within **0.15px** of
where the ball actually stops. Both also read their launch velocity from `aimVector`, so there is
no second place for the two to disagree.

Dots are spaced by arc length, not by time; even time spacing smears them over the fast opening arc
and piles them into a blob wherever the ball is slow.

## Architecture (TEA)

Model / Msg / update / view, with effects described as `cmd` values and interpreted by `Game.res`.
`update` is pure — `npm test` runs 62 assertions against it in plain Node with no DOM, covering the
stroke cycle, hole progression, phase guards, the resize invariants, and the whole scoring and
save-format surface.

Two things are worth knowing before editing `View.res`:

- **The view diffs against the previous model, and that is correctness, not optimisation.**
  Re-assigning `animation` on the ball *restarts the shot*, so the view must not touch an animation
  property unless `shotId` actually changed.
- **The ball's position during flight is deliberately not in the model.** The browser owns it while
  the keyframes play; the model only knows which shot is in flight. `animationend` is the only
  frame signal in the game, and it resolves to `shot.endX/endY`.

Installing keyframes is a view concern rather than a `cmd`, because it is a pure function of
`(program, shotId)` — modelling it as a command would give two places the power to start an
animation.

## World coordinates

The course is generated in a fixed **1000 x 600** virtual space and projected with a single
`transform: scale()` on `#world`. Everything below that element — terrain, ball, cup, trail,
and the generated `@keyframes` — is authored in world units and never sees the screen size.

This is what makes "hole N is always the same course" true. Generating in screen pixels made the
shape depend on the window, and meant a resize rebuilt the course underneath the ball.

Scale is `viewportWidth / 1000`: the gameplay axis is horizontal, so the whole hole is always
visible and spare vertical space simply becomes more sky. Terrain is clamped to 0.60 of world
height, so the dunes need only `0.36 x viewportWidth` of vertical room — true of any real screen.

**Known trade-off:** on a tall portrait phone this leaves the course as a small band at the bottom
(a 5:3 world does not fit a 1:2 screen). Landscape is excellent. Fixing portrait properly means a
camera that scales to fit height and pans horizontally to follow the ball.

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
