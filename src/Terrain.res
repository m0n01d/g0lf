// The course is a polyline sampled every `step` px. Storing it as a polyline
// (rather than an analytic curve) matters for the CSS trick: within any single
// span the slope is constant, so a rolling ball has constant acceleration —
// which is exactly what a cubic-bezier can express.

type t = {
  step: float,
  ys: array<float>, // world height (y up, 0 = bottom of stage) at x = i * step
  width: float,
  height: float,
  teeX: float,
  teeY: float,
  holeX: float,
  holeY: float,
}

let cupR = 14.0

let clamp = (v: float, lo, hi) => v < lo ? lo : v > hi ? hi : v
let clampI = (v: int, lo, hi) => v < lo ? lo : v > hi ? hi : v

let index = (t: t, x: float) => {
  let i = Int.fromFloat(x /. t.step)
  clampI(i, 0, Array.length(t.ys) - 2)
}

let heightAt = (t: t, x: float) => {
  let i = index(t, x)
  let f = clamp(x /. t.step -. Int.toFloat(i), 0.0, 1.0)
  let a = Array.getUnsafe(t.ys, i)
  let b = Array.getUnsafe(t.ys, i + 1)
  a +. (b -. a) *. f
}

let slopeAt = (t: t, x: float) => {
  let i = index(t, x)
  (Array.getUnsafe(t.ys, i + 1) -. Array.getUnsafe(t.ys, i)) /. t.step
}

// Smooth 0..1 ramp, used to blend flat pads into the dunes without a seam.
let smoothstep = e => {
  let e = clamp(e, 0.0, 1.0)
  e *. e *. (3.0 -. 2.0 *. e)
}

// Pull the terrain toward a single height around `cx`, so tees and cups sit on
// a believable little plateau instead of a random slope.
let flatten = (ys, ~step, ~cx, ~radius) => {
  let at = x => {
    let i = clampI(Int.fromFloat(x /. step), 0, Array.length(ys) - 1)
    Array.getUnsafe(ys, i)
  }
  let target = at(cx)
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    let d = Math.abs(x -. cx) /. radius
    let w = 1.0 -. smoothstep(d)
    Array.setUnsafe(ys, i, y +. (target -. y) *. w)
  })
}

// Layered sines: cheap, smooth, and reads as rolling dunes rather than noise.
let dunes = (r: Rand.t, ~width, ~step, ~count, ~base, ~amp) => {
  let waves = Array.fromInitializer(~length=5, i => {
    let k = Int.toFloat(i + 1)
    (Rand.range(r, 0.55, 1.35) *. amp /. k, k *. Rand.range(r, 0.7, 1.6), Rand.range(r, 0.0, 6.2832))
  })
  Array.fromInitializer(~length=count, i => {
    let x = Int.toFloat(i) *. step /. width
    Array.reduce(waves, base, (acc, (a, f, p)) => acc +. a *. Math.sin(x *. f *. 6.2832 +. p))
  })
}

let generate = (~seed, ~width, ~height) => {
  let r = Rand.make(seed)
  let step = 8.0
  let count = Int.fromFloat(width /. step) + 3

  let ys = dunes(r, ~width, ~step, ~count, ~base=height *. 0.30, ~amp=height *. 0.075)

  // Dunes rise at both ends, so the course has natural walls instead of an
  // invisible boundary.
  let berm = 120.0
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    let e = Math.min(x, width -. x) /. berm
    Array.setUnsafe(ys, i, y +. height *. 0.13 *. (1.0 -. smoothstep(e)))
  })

  // Keep the horizon low enough that there is always sky to hit a ball through.
  Array.forEachWithIndex(ys, (y, i) =>
    Array.setUnsafe(ys, i, clamp(y, height *. 0.08, height *. 0.56))
  )

  let teeX = width *. Rand.range(r, 0.10, 0.16)
  let holeX = width *. Rand.range(r, 0.55, 0.88)

  flatten(ys, ~step, ~cx=teeX, ~radius=70.0)
  flatten(ys, ~step, ~cx=holeX, ~radius=54.0)

  let t = {
    step,
    ys,
    width,
    height,
    teeX,
    teeY: 0.0,
    holeX,
    holeY: 0.0,
  }
  {...t, teeY: heightAt(t, teeX), holeY: heightAt(t, holeX)}
}

// Decorative background ridges. No physics, just parallax depth.
let backdrop = (~seed, ~width, ~height, ~layer) => {
  let r = Rand.make(seed * 977 + layer * 31)
  let step = 26.0
  let count = Int.fromFloat(width /. step) + 3
  dunes(
    r,
    ~width,
    ~step,
    ~count,
    ~base=height *. (0.34 +. 0.07 *. Int.toFloat(layer)),
    ~amp=height *. 0.07,
  )
}
