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

/** The one shaped obstacle a hole is built around. */
type feature =
  | Dunes // plain rolling ground
  | Ridge // a hump between tee and cup that has to be carried
  | Gully // a dip between tee and cup that has to be cleared
  | Plateau // the cup sits on a mesa you have to land on
  | Bowl // the cup sits in a basin that funnels the ball in

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
/**
Level the ground around `cx`.

`core` is truly flat — that is the landing pad, and shrinking it is what makes
later cups less forgiving. `skirt` is the blend back into the dunes, and it is
kept wide on purpose: a narrow blend against tall surrounding terrain is itself
a cliff, which is how a "small pad" quietly becomes an unplayable pit.
*/
let flatten = (ys, ~step, ~cx, ~core, ~skirt) => {
  let at = x => {
    let i = clampI(Int.fromFloat(x /. step), 0, Array.length(ys) - 1)
    Array.getUnsafe(ys, i)
  }
  let target = at(cx)
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    let d = Math.abs(x -. cx)
    let w = d <= core ? 1.0 : 1.0 -. smoothstep((d -. core) /. skirt)
    Array.setUnsafe(ys, i, y +. (target -. y) *. w)
  })
}

/**
How hard hole N should be, as 0..1. Ramps over the first couple of dozen holes
and then holds — an infinite course cannot keep escalating forever without
becoming unplayable.
*/
let difficulty = hole => clamp((Int.toFloat(hole) -. 1.0) /. 34.0, 0.0, 1.0)

/**
Keep terrain inside a height band by compressing toward it rather than clipping
at it. A hard clamp turns every tall dune into a flat-topped mesa and every
steep face into a cliff; this bends them into rounded crests instead.
*/
let softLimit = (y, ~lo, ~hi) => {
  let mid = (lo +. hi) *. 0.5
  let half = (hi -. lo) *. 0.5
  mid +. half *. Math.tanh((y -. mid) /. half)
}

/**
Add a smooth Gaussian hump (or dip, for a negative amount) centred on `cx`.
This is how the named course features are built: a ridge to carry, a gully to
clear, a mesa to land on, a bowl that funnels.
*/
let bump = (ys, ~step, ~cx, ~w, ~amount) =>
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    let u = (x -. cx) /. w
    Array.setUnsafe(ys, i, y +. amount *. Math.exp(-.(u *. u) *. 2.2))
  })


/**
Cap how steep any single span may be.

Stacked octaves can add up to a near-vertical face, which stops reading as a
dune and turns into a wall the ball just ricochets off. Two smoothing sweeps —
forward then back — pull any over-steep span down without flattening the shape
around it.
*/
let limitSlope = (ys, ~step, ~maxSlope) => {
  let n = Array.length(ys)
  let maxD = maxSlope *. step
  for _pass in 0 to 2 {
    for i in 1 to n - 1 {
      let a = Array.getUnsafe(ys, i - 1)
      let b = Array.getUnsafe(ys, i)
      if b -. a > maxD {
        Array.setUnsafe(ys, i, a +. maxD)
      } else if a -. b > maxD {
        Array.setUnsafe(ys, i, a -. maxD)
      }
    }
    for i in n - 2 downto 0 {
      let a = Array.getUnsafe(ys, i + 1)
      let b = Array.getUnsafe(ys, i)
      if b -. a > maxD {
        Array.setUnsafe(ys, i, a +. maxD)
      } else if a -. b > maxD {
        Array.setUnsafe(ys, i, a -. maxD)
      }
    }
  }
}

/**
Layered sines: cheap, smooth, and reads as rolling dunes rather than noise.

`detail` (0..1) slows the amplitude falloff and spreads the frequencies, so
later holes are choppier. The falloff exponent stays above 1 on purpose: each
octave's slope contribution has to keep shrinking, or the high octaves stack
into cliffs.
*/
let dunes = (r: Rand.t, ~width, ~step, ~count, ~base, ~amp, ~detail) => {
  let falloff = 1.65 -. 0.4 *. detail
  let spread = 1.0 +. 0.3 *. detail
  let waves = Array.fromInitializer(~length=5, i => {
    let k = Int.toFloat(i + 1)
    (
      Rand.range(r, 0.55, 1.35) *. amp /. Math.pow(k, ~exp=falloff),
      k *. Rand.range(r, 0.7, 1.6) *. spread,
      Rand.range(r, 0.0, 6.2832),
    )
  })
  Array.fromInitializer(~length=count, i => {
    let x = Int.toFloat(i) *. step /. width
    Array.reduce(waves, base, (acc, (a, f, p)) => acc +. a *. Math.sin(x *. f *. 6.2832 +. p))
  })
}

/**
Build hole N. `hole` is both the seed and the difficulty input, so a given hole
number is always the same course and always the same challenge.
*/
let generate = (~hole, ~width, ~height) => {
  let r = Rand.make(hole)
  let d = difficulty(hole)
  let step = 8.0
  let count = Int.fromFloat(width /. step) + 3

  // Tee and cup are chosen first, because the course feature is placed relative
  // to the line between them.
  let teeX = width *. Rand.range(r, 0.09, 0.15)
  let reach = 0.40 +. 0.26 *. d
  let holeX = clamp(
    teeX +. width *. Rand.range(r, reach, reach +. 0.20),
    teeX +. 150.0,
    width -. 95.0,
  )

  let ys = dunes(
    r,
    ~width,
    ~step,
    ~count,
    ~base=height *. 0.30,
    ~amp=height *. (0.07 +. 0.10 *. d),
    ~detail=d,
  )

  // One shaped feature per hole, drawn from a pool that widens as the round
  // goes on. Early holes are plain dunes; a bowl is a gift; a ridge or gully
  // has to be carried; a mesa has to be landed on.
  let pool = if d < 0.16 {
    [Dunes]
  } else if d < 0.34 {
    [Dunes, Dunes, Bowl, Ridge]
  } else if d < 0.62 {
    [Dunes, Bowl, Ridge, Ridge, Gully, Plateau]
  } else {
    [Bowl, Ridge, Ridge, Gully, Gully, Plateau, Plateau]
  }
  let feature = Array.getUnsafe(
    pool,
    clampI(Int.fromFloat(Rand.float(r) *. Int.toFloat(Array.length(pool))), 0, Array.length(pool) - 1),
  )

  // Carry features sit somewhere between the tee and the cup; cup features sit
  // on the cup.
  let between = teeX +. (holeX -. teeX) *. Rand.range(r, 0.34, 0.62)
  switch feature {
  | Dunes => ()
  | Ridge =>
    bump(ys, ~step, ~cx=between, ~w=width *. 0.085, ~amount=height *. (0.15 +. 0.20 *. d))
  | Gully =>
    bump(ys, ~step, ~cx=between, ~w=width *. 0.105, ~amount=-.height *. (0.12 +. 0.15 *. d))
  | Plateau =>
    bump(ys, ~step, ~cx=holeX, ~w=width *. 0.075, ~amount=height *. (0.11 +. 0.15 *. d))
  | Bowl => bump(ys, ~step, ~cx=holeX, ~w=width *. 0.15, ~amount=-.height *. (0.09 +. 0.11 *. d))
  }

  // Dunes rise at both ends, so the course has natural walls instead of an
  // invisible boundary.
  let berm = 120.0
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    let e = Math.min(x, width -. x) /. berm
    Array.setUnsafe(ys, i, y +. height *. 0.13 *. (1.0 -. smoothstep(e)))
  })

  // Keep a playable band of sky above the terrain, without flattening crests.
  Array.forEachWithIndex(ys, (y, i) =>
    Array.setUnsafe(ys, i, softLimit(y, ~lo=height *. 0.07, ~hi=height *. 0.60))
  )

  // The cup's landing pad shrinks as the round goes on: less and less room to
  // stop the ball. The tee stays generous.
  // Last word on the raw shape. Runs before the pads so it can never tilt one:
  // flatten's wide skirt means the pads cannot reintroduce a cliff.
  limitSlope(ys, ~step, ~maxSlope=1.3)

  // The cup's flat core shrinks as the round goes on — less and less room to
  // stop the ball. The tee stays generous.
  //
  // Limiting and flattening fight each other: the limiter can tilt a small pad,
  // and a pad's skirt against tall neighbouring terrain is itself steep. Two
  // rounds converge — by the second pass the pad's surroundings are already
  // close to pad height, so neither correction has anything left to do.
  let pads = () => {
    flatten(ys, ~step, ~cx=teeX, ~core=46.0, ~skirt=80.0)
    flatten(ys, ~step, ~cx=holeX, ~core=34.0 -. 16.0 *. d, ~skirt=88.0)
  }
  pads()
  limitSlope(ys, ~step, ~maxSlope=1.3)
  pads()

  let t = {step, ys, width, height, teeX, teeY: 0.0, holeX, holeY: 0.0}
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
    ~detail=0.0,
  )
}
