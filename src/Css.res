// Physics -> CSS.
//
// The trick this whole prototype rests on:
//
//   Over one segment, a ball under constant acceleration moves as a quadratic
//   in time. A cubic Bezier can represent a quadratic *exactly* (elevate the
//   degree). So every segment of a golf shot has an exact `cubic-bezier(...)`.
//
//   Normalise a segment to run 0..1 in both time and displacement. Let
//       b = v0 * T / (p1 - p0)      (initial speed as a fraction of average speed)
//   Then the motion is  f(u) = b*u + (1 - b)*u^2 , and the exact easing is
//       cubic-bezier(1/3, b/3, 2/3, (1+b)/3)
//
//   Sanity check the three cases you already know:
//       b = 1  ->  cubic-bezier(.333,.333,.667,.667)   = linear      (constant speed)
//       b = 0  ->  cubic-bezier(.333,0,.667,.333)      = quad ease-in  (dropped from rest)
//       b = 2  ->  cubic-bezier(.333,.667,.667,1)      = quad ease-out (rising to apex)
//
// So a rising arc is a quadratic ease-out, a falling arc is a quadratic ease-in,
// and horizontal flight is linear. Not "looks like" — is.
//
// X and Y are put on two nested elements so they can carry independent easings,
// which is what lets a parabola come out of two 1-D animations.

let num = (v: float) => {
  let s = v->Float.toFixed(~digits=4)
  s
}

let bezier = (~p0, ~p1, ~v0, ~dt) => {
  let d = p1 -. p0
  // A segment with no meaningful travel has no meaningful easing.
  if dt <= 0.0 || Math.abs(d) < 0.35 {
    "linear"
  } else {
    let b = v0 *. dt /. d
    // Segments are split at every apex and reversal, so b lives near [0,2].
    // The clamp only exists so a numeric edge case can never emit a wild curve.
    let b = Terrain.clamp(b, -6.0, 6.0)
    `cubic-bezier(0.3333,${num(b /. 3.0)},0.6667,${num((1.0 +. b) /. 3.0)})`
  }
}

type track = {
  // value at a stop, and the rate of change (per second) leaving that stop
  value: Physics.stop => float,
  rate: Physics.stop => float,
  // how the value is written into a CSS declaration
  decl: float => string,
}

let keyframes = (~name, ~stops: array<Physics.stop>, ~duration, ~track) => {
  let n = Array.length(stops)
  let body = []

  for i in 0 to n - 1 {
    let s = Array.getUnsafe(stops, i)
    let pct = duration <= 0.0 ? 0.0 : s.t /. duration *. 100.0
    let ease = if i < n - 1 {
      let next = Array.getUnsafe(stops, i + 1)
      let e = bezier(
        ~p0=track.value(s),
        ~p1=track.value(next),
        ~v0=track.rate(s),
        ~dt=next.t -. s.t,
      )
      `animation-timing-function:${e};`
    } else {
      ""
    }
    Array.push(body, `${num(pct)}%{${track.decl(track.value(s))}${ease}}`)
  }

  `@keyframes ${name}{${Array.join(body, "")}}`
}

// Drop stops that land on the same percentage; duplicates make the browser
// keep only the last one and silently lose an easing.
let dedupe = (stops: array<Physics.stop>) => {
  let out: array<Physics.stop> = []
  Array.forEach(stops, s =>
    switch Array.at(out, -1) {
    | Some(prev) if s.t -. prev.t < 1.0e-4 => ()
    | _ => Array.push(out, s)
    }
  )
  out
}

/** Hard ceiling on how many keyframes one shot may emit. */
let budget = 160

/**
Enforce `budget`.

A degenerate roll — a ball creeping along a crease on very broken ground — can
otherwise produce thousands of stops and megabytes of CSS, which is a stutter
rather than an animation. Flight stops carry the arc and are few, so they are
always kept; surplus rolling stops are subsampled evenly.

This bounds the pathological case only: a normal shot is an order of magnitude
under the budget and passes through untouched, still exact.
*/
let thin = (stops: array<Physics.stop>) => {
  let n = Array.length(stops)
  if n <= budget {
    stops
  } else {
    let flights = Array.reduce(stops, 0, (a, s) => s.flying ? a + 1 : a)
    let rolls = n - flights
    let room = budget - flights - 2
    let every = room <= 0 ? rolls : Int.fromFloat(Math.ceil(Int.toFloat(rolls) /. Int.toFloat(room)))
    let every = every < 1 ? 1 : every
    let out = []
    let seen = ref(0)
    Array.forEachWithIndex(stops, (s, i) => {
      if i == 0 || i == n - 1 || s.flying {
        Array.push(out, s)
      } else {
        if Int.mod(seen.contents, every) == 0 {
          Array.push(out, s)
        }
        seen := seen.contents + 1
      }
    })
    out
  }
}

// Everything the DOM needs for one shot: the stylesheet text plus the names.
type program = {
  css: string,
  nameX: string,
  nameY: string,
  nameSpin: string,
  nameShadow: string,
  duration: float,
  spinEnd: float,
}

// Degrees of ball rotation per px of horizontal travel. Slightly under the
// true rolling rate — a true rate reads as frantic at this ball size.
let spinPerPx = 57.2958 /. Physics.ballR *. 0.55

let compile = (shot: Physics.shot, ~stageH, ~id, ~spin0) => {
  let stops = thin(dedupe(shot.stops))
  let first = Array.getUnsafe(stops, 0)
  let duration = shot.duration

  // Screen space: y grows downward, so world velocities flip sign.
  let originX = first.x
  let originY = stageH -. first.y

  let nameX = `sx${Int.toString(id)}`
  let nameY = `sy${Int.toString(id)}`
  let nameSpin = `sr${Int.toString(id)}`
  let nameShadow = `sh${Int.toString(id)}`

  let kx = keyframes(
    ~name=nameX,
    ~stops,
    ~duration,
    ~track={
      value: s => s.x -. originX,
      rate: s => s.vx,
      decl: v => `transform:translate3d(${num(v)}px,0,0);`,
    },
  )

  let ky = keyframes(
    ~name=nameY,
    ~stops,
    ~duration,
    ~track={
      value: s => stageH -. s.y -. originY,
      rate: s => -.s.vy,
      decl: v => `transform:translate3d(0,${num(v)}px,0);`,
    },
  )

  // Rotation is an affine function of horizontal travel, so it reuses the exact
  // same easing curves as the X track for free.
  let kr = keyframes(
    ~name=nameSpin,
    ~stops,
    ~duration,
    ~track={
      value: s => spin0 +. (s.x -. originX) *. spinPerPx,
      rate: s => s.vx *. spinPerPx,
      decl: v => `transform:rotate(${num(v)}deg);`,
    },
  )

  // The shadow rides the terrain under the ball and fades with altitude.
  let kh = keyframes(
    ~name=nameShadow,
    ~stops,
    ~duration,
    ~track={
      value: s => stageH -. s.gy -. originY,
      rate: _ => 0.0,
      decl: v => `transform:translate3d(0,${num(v)}px,0);`,
    },
  )

  let opacity = {
    let body = Array.mapWithIndex(stops, (s, _) => {
      let pct = duration <= 0.0 ? 0.0 : s.t /. duration *. 100.0
      let air = Terrain.clamp((s.y -. Physics.ballR -. s.gy) /. 180.0, 0.0, 1.0)
      let o = 0.30 -. 0.24 *. air
      let sc = 1.0 -. 0.45 *. air
      `${num(pct)}%{opacity:${num(o)};scale:${num(sc)} ${num(sc *. 0.55)};}`
    })
    `@keyframes ${nameShadow}o{${Array.join(body, "")}}`
  }

  {
    css: `${kx}${ky}${kr}${kh}${opacity}`,
    nameX,
    nameY,
    nameSpin,
    nameShadow,
    duration,
    spinEnd: spin0 +. (shot.endX -. originX) *. spinPerPx,
  }
}
