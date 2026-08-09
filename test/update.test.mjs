// The payoff of the TEA rewrite: the game's state machine is exercised here in
// plain Node, with no DOM, no browser and no timers.
import * as M from "../src/Model.res.mjs"
import * as U from "../src/Update.res.mjs"
import * as T from "../src/Terrain.res.mjs"
import * as P from "../src/Physics.res.mjs"
import * as S from "../src/Score.res.mjs"

let pass = 0, fail = 0
const ok = (name, cond, extra = "") => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name + (extra ? "  -> " + extra : "")) }
}
const phase = m => (typeof m.phase === "object" ? m.phase.TAG : m.phase)

// Msg constructors: variants with payloads are {TAG, _0}; constant ones are strings.
const PointerDown = p => ({ TAG: "PointerDown", _0: p })
const PointerMoved = p => ({ TAG: "PointerMoved", _0: p })
const Rescaled = s => ({ TAG: "Rescaled", _0: s })
const PointerUp = "PointerUp", ShotEnded = "ShotEnded", ToggledCheat = "ToggledCheat"
const AdvanceHole = "AdvanceHole", PointerCancelled = "PointerCancelled"

const step = (m, msg) => { const [next, cmd] = U.update(m, msg); return { m: next, cmd } }

// --- a full stroke ----------------------------------------------------------
let m = M.init(0.9, S.empty)
ok("starts Ready on hole 1", phase(m) === "Ready" && m.run.hole === 1 && m.strokes === 0)

let r = step(m, PointerDown({ x: m.ball.x, y: m.ball.y }))
ok("pointer down starts aiming", phase(r.m) === "Aiming")
ok("aiming clears the intro toast", r.m.toast === undefined)

r = step(r.m, PointerMoved({ x: m.ball.x - 160, y: m.ball.y - 120 }))
ok("pointer move updates the aim", r.m.phase._0.to_.x === m.ball.x - 160)

const beforeShot = r.m
r = step(r.m, PointerUp)
ok("release fires a shot", phase(r.m) === "Watching")
ok("release counts a stroke", r.m.strokes === 1, "strokes=" + r.m.strokes)
ok("release compiles a program", r.m.program !== undefined)
ok("shotId advanced", r.m.shotId === beforeShot.shotId + 1)
ok("ball has not moved yet (browser owns it)", r.m.ball.x === beforeShot.ball.x)

const flying = r.m
r = step(flying, ShotEnded)
ok("shot end leaves Watching", phase(r.m) !== "Watching")
ok("shot end moves the ball to where the shot ended",
  Math.abs(r.m.ball.x - flying.phase._0.endX) < 1e-9)

// --- messages that do not apply to the phase are ignored ---------------------
const ignored = step(flying, PointerDown({ x: 0, y: 0 }))
ok("pointer down during flight is ignored", ignored.m === flying || phase(ignored.m) === "Watching")
const strayEnd = step(m, ShotEnded)
ok("stray ShotEnded while Ready is ignored", phase(strayEnd.m) === "Ready")
const strayAdvance = step(m, AdvanceHole)
ok("stray AdvanceHole while Ready is ignored", strayAdvance.m.run.hole === 1)

// --- a weak drag does not burn a stroke -------------------------------------
let w = step(M.init(0.9, S.empty), PointerDown({ x: 100, y: 100 }))
w = step(w.m, PointerMoved({ x: 101, y: 100 }))
w = step(w.m, PointerUp)
ok("a tiny drag does not count a stroke", w.m.strokes === 0 && phase(w.m) === "Ready")

// --- holing out: find a sinking shot and drive it through update -------------
const findSink = (model) => {
  for (let a = -10; a <= 190; a += 2)
    for (let sp = 120; sp <= 1280; sp += 20) {
      const rad = a * Math.PI / 180
      const s = P.simulate(model.course, model.ball.x, model.ball.y,
        Math.cos(rad) * sp, Math.sin(rad) * sp)
      if (s.outcome === "Sunk") return { vx: Math.cos(rad) * sp, vy: Math.sin(rad) * sp }
    }
  return null
}
let g = M.init(0.9, S.empty)
const sol = findSink(g)
ok("hole 1 is sinkable", sol !== null)
// aimVector maps drag -> velocity; invert it to build the drag that produces `sol`.
const speed = Math.hypot(sol.vx, sol.vy)
const len = 190 * Math.min(1, speed / 1280)
g = step(g, PointerDown({ x: g.ball.x, y: g.ball.y })).m
g = step(g, PointerMoved({ x: g.ball.x - (sol.vx / speed) * len, y: g.ball.y - (sol.vy / speed) * len })).m
let sunk = step(g, PointerUp)
ok("the holing drag reproduces a sinking shot", sunk.m.phase._0.outcome === "Sunk",
  "outcome=" + sunk.m.phase._0.outcome)
const strokesAtSink = sunk.m.strokes
sunk = step(sunk.m, ShotEnded)
ok("sinking goes to Between", phase(sunk.m) === "Between")
ok("sinking banks the strokes into total", sunk.m.run.total === strokesAtSink,
  `total=${sunk.m.run.total} strokes=${strokesAtSink}`)
ok("sinking announces itself", typeof sunk.m.toast === "string", JSON.stringify(sunk.m.toast))
ok("sinking schedules follow-up commands", sunk.cmd.TAG === "Batch" && sunk.cmd._0.length === 3)

const advanced = step(sunk.m, AdvanceHole)
// Score.record already advanced the counter when the ball dropped; AdvanceHole
// only builds the next course, so there is no second increment to check for.
ok("the hole counter advanced exactly once", advanced.m.run.hole === 2)
ok("advancing builds that hole's course", advanced.m.course.holeX === T.generate(2).holeX)
ok("advancing resets strokes but keeps total",
  advanced.m.strokes === 0 && advanced.m.run.total === strokesAtSink)
ok("advancing re-tees the ball", Math.abs(advanced.m.ball.x - advanced.m.course.teeX) < 1e-9)
ok("advancing is Ready", phase(advanced.m) === "Ready")

// --- the bug this rewrite was meant to kill ---------------------------------
const mid = step(step(M.init(0.9, S.empty), PointerDown({ x: 300, y: 300 })).m, PointerMoved({ x: 200, y: 250 })).m
const resized = step(mid, Rescaled(0.42))
ok("a resize does not move the ball", resized.m.ball.x === mid.ball.x && resized.m.ball.y === mid.ball.y)
ok("a resize does not rebuild the course", resized.m.course === mid.course)
ok("a resize does not reset the hole or strokes",
  resized.m.hole === mid.hole && resized.m.strokes === mid.strokes)
ok("a resize only changes the projection", resized.m.scale === 0.42)

// --- courses are device independent -----------------------------------------
const c1 = T.generate(7), c2 = T.generate(7)
ok("hole 7 is identical every time",
  c1.holeX === c2.holeX && c1.teeX === c2.teeX && c1.ys.every((v, i) => v === c2.ys[i]))

// --- cheat toggle -----------------------------------------------------------
const t1 = step(M.init(0.9, S.empty), ToggledCheat)
ok("cheat toggles on", t1.m.run.cheat === true)
ok("cheat toggles off", step(t1.m, ToggledCheat).m.run.cheat === false)
ok("toggling the cheat persists it", t1.cmd.TAG === "Persist")

// --- cancel -----------------------------------------------------------------
const cancelled = step(step(M.init(0.9, S.empty), PointerDown({ x: 100, y: 100 })).m, PointerCancelled)
ok("pointer cancel returns to Ready without a stroke",
  phase(cancelled.m) === "Ready" && cancelled.m.strokes === 0)


// --- scoring -----------------------------------------------------------------
const ResetPressed = "ResetPressed", ResetDisarmed = "ResetDisarmed"

ok("a fresh run has no average", S.average(S.empty) === undefined)

let run = S.empty
run = S.record(run, 3)
ok("recording a hole advances the counter", run.hole === 2)
ok("recording a hole banks the strokes", run.total === 3)
ok("first finished hole sets the best", run.best === 3 && run.bestHole === 1)
ok("average after one hole", Math.abs(S.average(run) - 3) < 1e-9)

run = S.record(run, 1)
ok("an ace is counted", run.aces === 1)
ok("a better hole lowers the best", run.best === 1 && run.bestHole === 2)
ok("average tracks both holes", Math.abs(S.average(run) - 2) < 1e-9)

run = S.record(run, 5)
ok("a worse hole leaves the best alone", run.best === 1 && run.bestHole === 2)

// round-trip through the save format
const wire = S.encode(run)
const back = S.decode(wire)
ok("a run survives encode/decode", back !== undefined && JSON.stringify(back) === JSON.stringify(run),
  wire + " -> " + JSON.stringify(back))
ok("garbage in storage is rejected, not misread", S.decode("not a save") === undefined)
ok("a future save version is rejected", S.decode("99|1|0|0|0|0|0") === undefined)
ok("a truncated save is rejected", S.decode("1|5|10") === undefined)

// sinking persists, and the command says so
let sg = M.init(0.9, S.empty)
const sol2 = findSink(sg)
const sp2 = Math.hypot(sol2.vx, sol2.vy), ln2 = 190 * Math.min(1, sp2 / 1280)
sg = step(sg, PointerDown({ x: sg.ball.x, y: sg.ball.y })).m
sg = step(sg, PointerMoved({ x: sg.ball.x - (sol2.vx / sp2) * ln2, y: sg.ball.y - (sol2.vy / sp2) * ln2 })).m
let done = step(step(sg, PointerUp).m, ShotEnded)
ok("sinking emits a Persist command",
  done.cmd.TAG === "Batch" && done.cmd._0.some(c => c.TAG === "Persist"))
ok("sinking advances the persisted hole", done.m.run.hole === 2)
ok("a one-shot hole is recorded as an ace", done.m.run.aces === 1, "aces=" + done.m.run.aces)

// resuming
const resumed = M.init(0.9, { hole: 12, total: 30, aces: 2, best: 1, bestHole: 4, cheat: true })
ok("resuming restores the hole", resumed.run.hole === 12)
ok("resuming restores the cheat toggle", resumed.run.cheat === true)
ok("resuming rebuilds that hole's course", resumed.course.holeX === T.generate(12).holeX)
ok("resuming starts at the tee with no strokes", resumed.strokes === 0)
ok("resuming reports the carried average", Math.abs(S.average(resumed.run) - 30 / 11) < 1e-9)

// reset needs two presses
let armed = step(resumed, ResetPressed)
ok("one press only arms the reset", armed.m.resetArmed === true && armed.m.run.hole === 12)
ok("arming schedules a disarm", armed.cmd.TAG === "After")
ok("the disarm timer clears it", step(armed.m, ResetDisarmed).m.resetArmed === false)
const wiped = step(armed.m, ResetPressed)
ok("the second press wipes the run", wiped.m.run.hole === 1 && wiped.m.run.total === 0)
ok("wiping emits Forget",
  wiped.cmd.TAG === "Batch" && wiped.cmd._0.some(c => c === "Forget" || c.TAG === "Forget"))
ok("a disarmed reset does not wipe", step(resumed, ResetDisarmed).m.run.hole === 12)


// --- redraw keying ------------------------------------------------------------
// Regression: the view used to key the terrain redraw on run.hole. Sinking
// advances that counter while the old course is still on screen, and the new
// course arrives one message later on AdvanceHole — so the DOM sat one hole
// behind. The predicate lives in Model precisely so it can be checked here.
{
  let g = M.init(0.9, S.empty)
  ok("first render always draws", M.needsRedraw(undefined, g) === true)
  ok("an unchanged model does not redraw", M.needsRedraw(g, g) === false)

  const moved = step(g, PointerDown({ x: 100, y: 100 })).m
  ok("aiming does not redraw the terrain", M.needsRedraw(g, moved) === false)

  const sol3 = findSink(g)
  const sp3 = Math.hypot(sol3.vx, sol3.vy), ln3 = 190 * Math.min(1, sp3 / 1280)
  let a1 = step(g, PointerDown({ x: g.ball.x, y: g.ball.y })).m
  a1 = step(a1, PointerMoved({ x: g.ball.x - (sol3.vx / sp3) * ln3, y: g.ball.y - (sol3.vy / sp3) * ln3 })).m
  const flying2 = step(a1, PointerUp).m
  const sunk2 = step(flying2, ShotEnded).m
  ok("sinking advances the hole counter but not the course",
    sunk2.run.hole === 2 && sunk2.course === g.course)
  ok("sinking must NOT redraw — the new course does not exist yet",
    M.needsRedraw(flying2, sunk2) === false)

  const next2 = step(sunk2, AdvanceHole).m
  ok("AdvanceHole swaps the course", next2.course !== sunk2.course)
  ok("AdvanceHole MUST redraw (this is the bug that shipped)",
    M.needsRedraw(sunk2, next2) === true)

  const wiped2 = step(step(next2, ResetPressed).m, ResetPressed).m
  ok("a reset redraws", M.needsRedraw(next2, wiped2) === true)
}


// --- no soft-lock without pointer capture -------------------------------------
// setPointerCapture was removed (it made Chromium fire pointercancel instead of
// pointerup once anything painted beneath #world). A missed pointerup must
// therefore never leave the game stuck in Aiming.
{
  let g = M.init(0.9, S.empty)
  const aiming = step(g, PointerDown({ x: 300, y: 300 })).m
  ok("a drag starts an aim", phase(aiming) === "Aiming")
  const reAimed = step(aiming, PointerDown({ x: 500, y: 400 })).m
  ok("pressing again while aiming restarts the aim, never locks",
    phase(reAimed) === "Aiming" && reAimed.phase._0.from.x === 500)
  ok("restarting an aim costs no stroke", reAimed.strokes === 0)
  const afterCancel = step(aiming, PointerCancelled).m
  ok("a cancelled gesture returns to Ready", phase(afterCancel) === "Ready")
  ok("and can immediately aim again", phase(step(afterCancel, PointerDown({ x: 1, y: 1 })).m) === "Aiming")
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
