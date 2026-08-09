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
  // Everything that survives closing the app.
  run: Score.t,
  strokes: int, // on the current hole; deliberately not persisted
  course: Terrain.t,
  ball: point, // world coords, y up; where the ball is at rest
  spin: float, // accumulated rotation, so it never snaps back between shots
  shotId: int,
  program: option<Css.program>,
  toast: option<string>,
  phase: phase,
  // Wiping a run that has taken hours needs a second press to confirm.
  resetArmed: bool,
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
  | ResetPressed
  | ResetDisarmed

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
  | Persist(Score.t)
  | Forget

let teeOf = (course: Terrain.t) => {x: course.teeX, y: course.teeY +. Physics.ballR}

let fresh = (~scale, ~run: Score.t, ~toast) => {
  let course = Terrain.generate(~hole=run.hole)
  {
    scale,
    run,
    strokes: 0,
    course,
    ball: teeOf(course),
    spin: 0.0,
    shotId: 0,
    program: None,
    toast,
    phase: Ready,
    resetArmed: false,
  }
}

let init = (~scale, ~run) =>
  fresh(
    ~scale,
    ~run,
    ~toast=run.hole == 1 && run.total == 0
      ? Some("drag back from the ball, then let go")
      : Some(`resuming at hole ${Int.toString(run.hole)}`),
  )

let isWatching = m =>
  switch m.phase {
  | Watching(_) => true
  | _ => false
  }
