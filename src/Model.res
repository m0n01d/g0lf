// The whole of the game's state, and the messages that can change it.
// Nothing in this module touches the DOM.

type point = {x: float, y: float}

type aim = {from: point, to_: point}

type phase =
  | Ready
  | Aiming(aim)
  // While a shot plays, the browser owns the ball's position — it is
  // interpolating the keyframes. The model only knows which shot is in flight
  // and, from it, where the ball will come to rest.
  | Watching(Physics.shot)
  | Between

type model = {
  // World units -> screen px. The only thing that depends on the viewport.
  scale: float,
  hole: int,
  strokes: int,
  total: int,
  course: Terrain.t,
  ball: point, // world coords, y up; where the ball is at rest
  spin: float, // accumulated rotation, so it never snaps back between shots
  cheat: bool,
  shotId: int,
  program: option<Css.program>,
  toast: option<string>,
  phase: phase,
}

type msg =
  | Rescaled(float)
  | PointerDown(point) // world coords
  | PointerMoved(point)
  | PointerUp
  | PointerCancelled
  | ShotEnded
  | ToggledCheat
  | AdvanceHole
  | ToastExpired

/**
Effects, described rather than performed.

Installing keyframes is deliberately not here: it is a pure function of
`(program, shotId)`, so the view performs it when `shotId` changes. Modelling it
as a command would mean two places could start an animation.
*/
type rec cmd =
  | NoCmd
  | Batch(array<cmd>)
  | After(int, msg)

let teeOf = (course: Terrain.t) => {x: course.teeX, y: course.teeY +. Physics.ballR}

let init = (~scale) => {
  let course = Terrain.generate(~hole=1)
  {
    scale,
    hole: 1,
    strokes: 0,
    total: 0,
    course,
    ball: teeOf(course),
    spin: 0.0,
    cheat: false,
    shotId: 0,
    program: None,
    toast: Some("drag back from the ball, then let go"),
    phase: Ready,
  }
}

let isWatching = m =>
  switch m.phase {
  | Watching(_) => true
  | _ => false
  }
