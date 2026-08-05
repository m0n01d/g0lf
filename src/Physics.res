// The whole shot is simulated up front, then handed to CSS as keyframes.
// Nothing here runs per-frame — this is called once, on release of the drag.
//
// The output is a list of `stop`s: the moments where the ball's acceleration
// changes (a bounce, an apex, a slope change). Between two stops the motion is
// exactly a constant-acceleration parabola, which Css.res converts into an
// exact cubic-bezier. So the browser is not approximating the arc: it is
// replaying it.

let gravity = 1500.0
let ballR = 7.0
let restitution = 0.42
let tangentLoss = 0.26
let rollMu = 0.62
let sinkSpeed = 380.0
let restSpeed = 14.0
// Flight segments are exact, so they are never subdivided. Rolling crosses
// terrain spans whose slopes differ slightly, so it gets a tolerance and a
// time cap instead of a stop at every 8px span boundary.
let slopeTol = 0.045
let maxRollSegment = 0.22
let maxFlight = 12.0

type stop = {
  t: float,
  x: float,
  y: float, // world y, up
  vx: float,
  vy: float,
  gy: float, // terrain height under the ball, for the shadow track
  flying: bool, // in the air for the segment that starts here
}

type outcome = Sunk | Rest

type shot = {
  stops: array<stop>,
  duration: float,
  outcome: outcome,
  endX: float,
  endY: float,
}

let sign = v => v > 0.0 ? 1.0 : v < 0.0 ? -1.0 : 0.0

let simulate = (terrain: Terrain.t, ~x0, ~y0, ~vx0, ~vy0) => {
  let dt = 1.0 /. 720.0

  let x = ref(x0)
  let y = ref(y0)
  let vx = ref(vx0)
  let vy = ref(vy0)
  let t = ref(0.0)
  let flying = ref(true)
  let done = ref(false)
  let outcome = ref(Rest)

  let stops = []
  let lastStop = ref(0.0)
  let segSlope = ref(Terrain.slopeAt(terrain, x0))

  let record = () => {
    segSlope := Terrain.slopeAt(terrain, x.contents)
    Array.push(
      stops,
      {
        t: t.contents,
        x: x.contents,
        y: y.contents,
        vx: vx.contents,
        vy: vy.contents,
        gy: Terrain.heightAt(terrain, x.contents),
        flying: flying.contents,
      },
    )
    lastStop := t.contents
  }

  record()

  while !done.contents && t.contents < maxFlight {
    let vyPrev = vy.contents
    let vxPrev = vx.contents
    let cut = ref(false)
    let frac = ref(1.0) // fraction of this step actually consumed

    if flying.contents {
      let xPrev = x.contents
      let yPrev = y.contents
      vy := vy.contents -. gravity *. dt
      let xNext = xPrev +. vx.contents *. dt
      // Trapezoidal in velocity, which is exact under constant acceleration.
      let yNext = yPrev +. (vyPrev +. vy.contents) *. 0.5 *. dt

      // Apex: y reverses, so the segment must be split here to stay monotonic.
      if vyPrev > 0.0 && vy.contents <= 0.0 {
        cut := true
      }

      if yNext > Terrain.heightAt(terrain, xNext) +. ballR {
        x := xNext
        y := yNext
      } else {
        // Bisect for the moment of contact. Landing on the exact surface point
        // (rather than wherever the fixed step happened to overshoot to) is what
        // keeps a bounce off a steep dune from drifting a few px.
        let lo = ref(0.0)
        let hi = ref(1.0)
        for _ in 0 to 13 {
          let m = (lo.contents +. hi.contents) *. 0.5
          let xm = xPrev +. (xNext -. xPrev) *. m
          let ym = yPrev +. (yNext -. yPrev) *. m
          if ym <= Terrain.heightAt(terrain, xm) +. ballR {
            hi := m
          } else {
            lo := m
          }
        }
        frac := hi.contents
        x := xPrev +. (xNext -. xPrev) *. hi.contents
        y := Terrain.heightAt(terrain, x.contents) +. ballR
        vy := vyPrev -. gravity *. dt *. hi.contents

        let s = Terrain.slopeAt(terrain, x.contents)
        let len = Math.sqrt(1.0 +. s *. s)
        let (nx, ny) = (-.s /. len, 1.0 /. len)
        let (tx, ty) = (1.0 /. len, s /. len)
        let vn = vx.contents *. nx +. vy.contents *. ny
        let vt = vx.contents *. tx +. vy.contents *. ty
        let vn = vn < 0.0 ? -.vn *. restitution : vn
        let vt = vt *. (1.0 -. tangentLoss)

        if vn < 74.0 {
          // Too shallow to leave the ground again — start rolling.
          flying := false
          vx := vt *. tx
          vy := vt *. ty
        } else {
          vx := vn *. nx +. vt *. tx
          vy := vn *. ny +. vt *. ty
        }
        cut := true
      }
    } else {
      // Rolling: gravity resolved along the slope, opposed by friction.
      let s = Terrain.slopeAt(terrain, x.contents)
      let denom = 1.0 +. s *. s
      let downhill = -.gravity *. s /. denom
      let grip = rollMu *. gravity /. denom

      // A ball wedged in the bottom of a notch is held by the two faces, no
      // matter how steep they are. Without this, terrain steeper than rollMu
      // leaves the ball creeping in the crease forever, emitting a keyframe
      // per step, and only the flight cap ends the shot.
      let notch =
        Terrain.slopeAt(terrain, x.contents -. terrain.step) < 0.0 &&
          Terrain.slopeAt(terrain, x.contents +. terrain.step) > 0.0

      // Static friction. Without this the ball chatters across vx = 0 forever
      // on any slope shallow enough to hold it, and every step becomes a
      // direction change — which is a keyframe.
      if Math.abs(vx.contents) < restSpeed && (Math.abs(s) <= rollMu || notch) {
        vx := 0.0
        vy := 0.0
        done := true
        cut := true
      } else {
        let next = vx.contents +. (downhill -. sign(vx.contents) *. grip) *. dt

        // Kinetic friction may bring the ball to rest, never reverse it.
        if sign(next) != sign(vx.contents) && Math.abs(s) <= rollMu {
          vx := 0.0
        } else {
          vx := next
        }

        x := x.contents +. vx.contents *. dt
        y := Terrain.heightAt(terrain, x.contents) +. ballR
        vy := vx.contents *. Terrain.slopeAt(terrain, x.contents)

        if sign(vx.contents) != sign(vxPrev) {
          cut := true
        }
        if Math.abs(Terrain.slopeAt(terrain, x.contents) -. segSlope.contents) > slopeTol {
          cut := true
        }
        if t.contents -. lastStop.contents >= maxRollSegment {
          cut := true
        }
      }
    }

    // The course ends in dune walls. Reflect rather than teleport, so the
    // segment either side of the wall is still a clean parabola.
    let lo = ballR
    let hi = terrain.width -. ballR
    if x.contents < lo || x.contents > hi {
      x := Terrain.clamp(x.contents, lo, hi)
      vx := -.vx.contents *. 0.4
      cut := true
    }

    // Sunk: over the cup, low enough, and slow enough to drop rather than skip.
    let speed = Math.sqrt(vx.contents *. vx.contents +. vy.contents *. vy.contents)
    if (
      Math.abs(x.contents -. terrain.holeX) < Terrain.cupR &&
      y.contents -. (terrain.holeY +. ballR) < ballR *. 1.4 &&
      vy.contents <= 40.0 &&
      speed < sinkSpeed
    ) {
      outcome := Sunk
      done := true
      cut := true
    }

    t := t.contents +. dt *. frac.contents
    if cut.contents {
      record()
    }
  }

  // Always pin a stop at the very end of the motion.
  let tail = Array.getUnsafe(stops, Array.length(stops) - 1)
  if t.contents -. tail.t > 1.0e-4 {
    record()
  }

  // A little drop into the cup. This tail is choreography, not simulation —
  // the ball is already at rest in the cup's mouth by here.
  if outcome.contents == Sunk {
    let lipT = t.contents +. 0.07
    Array.push(
      stops,
      {
        t: lipT,
        x: terrain.holeX,
        y: terrain.holeY +. ballR,
        vx: 0.0,
        vy: 0.0,
        gy: terrain.holeY,
        flying: false,
      },
    )
    Array.push(
      stops,
      {
        t: lipT +. 0.22,
        x: terrain.holeX,
        y: terrain.holeY -. Terrain.cupR *. 0.75,
        vx: 0.0,
        vy: 0.0,
        gy: terrain.holeY,
        flying: false,
      },
    )
  }

  let last = Array.getUnsafe(stops, Array.length(stops) - 1)
  {
    stops,
    duration: last.t,
    outcome: outcome.contents,
    endX: last.x,
    endY: last.y,
  }
}

/**
Position at an arbitrary time inside a shot.

Uses the same constant-acceleration model the CSS keyframes encode, so an aim
preview traces exactly what the browser is about to animate rather than a
second, independent approximation of it.
*/
let sample = (stops: array<stop>, time: float) => {
  let n = Array.length(stops)
  if n == 0 {
    (0.0, 0.0)
  } else if n == 1 {
    let s = Array.getUnsafe(stops, 0)
    (s.x, s.y)
  } else {
    let i = ref(0)
    while i.contents < n - 2 && Array.getUnsafe(stops, i.contents + 1).t <= time {
      i := i.contents + 1
    }
    let a = Array.getUnsafe(stops, i.contents)
    let b = Array.getUnsafe(stops, i.contents + 1)
    let dt = b.t -. a.t
    if dt <= 0.0 {
      (a.x, a.y)
    } else {
      let u = Terrain.clamp(time -. a.t, 0.0, dt)
      // Recover the segment's acceleration from its endpoints and entry speed.
      let ax = 2.0 *. (b.x -. a.x -. a.vx *. dt) /. (dt *. dt)
      let ay = 2.0 *. (b.y -. a.y -. a.vy *. dt) /. (dt *. dt)
      (a.x +. a.vx *. u +. 0.5 *. ax *. u *. u, a.y +. a.vy *. u +. 0.5 *. ay *. u *. u)
    }
  }
}
