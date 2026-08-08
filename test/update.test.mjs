// The payoff of the TEA rewrite: the game's state machine is exercised here in
// plain Node, with no DOM, no browser and no timers.
import * as M from "../src/Model.res.mjs"
import * as U from "../src/Update.res.mjs"
import * as T from "../src/Terrain.res.mjs"
import * as P from "../src/Physics.res.mjs"

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
let m = M.init(0.9)
ok("starts Ready on hole 1", phase(m) === "Ready" && m.hole === 1 && m.strokes === 0)

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
ok("stray AdvanceHole while Ready is ignored", strayAdvance.m.hole === 1)

// --- a weak drag does not burn a stroke -------------------------------------
let w = step(M.init(0.9), PointerDown({ x: 100, y: 100 }))
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
let g = M.init(0.9)
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
ok("sinking banks the strokes into total", sunk.m.total === strokesAtSink,
  `total=${sunk.m.total} strokes=${strokesAtSink}`)
ok("sinking announces itself", typeof sunk.m.toast === "string", JSON.stringify(sunk.m.toast))
ok("sinking schedules follow-up commands", sunk.cmd.TAG === "Batch" && sunk.cmd._0.length === 2)

const advanced = step(sunk.m, AdvanceHole)
ok("advancing increments the hole", advanced.m.hole === 2)
ok("advancing resets strokes but keeps total",
  advanced.m.strokes === 0 && advanced.m.total === strokesAtSink)
ok("advancing re-tees the ball", Math.abs(advanced.m.ball.x - advanced.m.course.teeX) < 1e-9)
ok("advancing is Ready", phase(advanced.m) === "Ready")

// --- the bug this rewrite was meant to kill ---------------------------------
const mid = step(step(M.init(0.9), PointerDown({ x: 300, y: 300 })).m, PointerMoved({ x: 200, y: 250 })).m
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
const t1 = step(M.init(0.9), ToggledCheat)
ok("cheat toggles on", t1.m.cheat === true)
ok("cheat toggles off", step(t1.m, ToggledCheat).m.cheat === false)

// --- cancel -----------------------------------------------------------------
const cancelled = step(step(M.init(0.9), PointerDown({ x: 100, y: 100 })).m, PointerCancelled)
ok("pointer cancel returns to Ready without a stroke",
  phase(cancelled.m) === "Ready" && cancelled.m.strokes === 0)

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
