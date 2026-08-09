// Pure state transitions. No DOM, no timers, no storage — so this module is
// testable in plain Node, which `npm test` does.

open Model

let maxDrag = 190.0 // world units of pull-back for full power
let maxSpeed = 1280.0
let resetWindow = 4000 // ms the reset button stays armed
/** How long the dunes take to reshape into the next hole. Must match --shift. */
let shiftMs = 1000

/**
What a drag would launch. Both the preview and the real shot read from here, so
they cannot disagree.

Points are in world coordinates with y up, so the drag vector needs no sign
flipping: pulling down-left launches up-right.
*/
let aimVector = (from: point, to_: point) => {
  let dx = from.x -. to_.x
  let dy = from.y -. to_.y
  let len = Math.sqrt(dx *. dx +. dy *. dy)
  let power = Terrain.clamp(len /. maxDrag, 0.0, 1.0)
  if len < 1.0e-4 {
    (0.0, 0.0, 0.0)
  } else {
    let speed = power *. maxSpeed
    (dx /. len *. speed, dy /. len *. speed, power)
  }
}

/** What the run says after a hole is finished. */
let sunkToast = (run: Score.t, ~strokes) => {
  let opening = switch strokes {
  | 1 => run.aces > 1 ? `hole in one — ${Int.toString(run.aces)} aces` : "hole in one"
  | n => `sunk in ${Int.toString(n)}`
  }
  switch Score.average(run) {
  | Some(avg) => `${opening} · avg ${Float.toFixed(avg, ~digits=2)}`
  | None => opening
  }
}

let settle = (model, shot: Physics.shot) => {
  let m = {...model, ball: {x: shot.endX, y: shot.endY}}
  switch shot.outcome {
  | Physics.Sunk =>
    // record() advances the hole counter, so AdvanceHole only has to build the
    // course — no second increment.
    let run = Score.record(m.run, ~strokes=m.strokes)
    (
      {...m, run, phase: Between, toast: Some(sunkToast(run, ~strokes=m.strokes))},
      Batch([Persist(run), After(650, AdvanceHole), After(2600, ToastExpired)]),
    )
  | Physics.Rest => ({...m, phase: Ready}, NoCmd)
  }
}

let launch = (model, from, to_) => {
  let (vx, vy, power) = aimVector(from, to_)
  if power <= 0.06 {
    ({...model, phase: Ready}, NoCmd)
  } else {
    let shot = Physics.simulate(model.course, ~x0=model.ball.x, ~y0=model.ball.y, ~vx0=vx, ~vy0=vy)
    let shotId = model.shotId + 1
    let program = Css.compile(shot, ~stageH=Terrain.worldH, ~id=shotId, ~spin0=model.spin)
    let m = {
      ...model,
      strokes: model.strokes + 1,
      spin: program.spinEnd,
      shotId,
      program: Some(program),
      toast: None,
    }
    // A shot too short to animate is settled immediately rather than handed to
    // the browser, because a zero-length animation never fires animationend.
    program.duration < 0.05 ? settle(m, shot) : ({...m, phase: Watching(shot)}, NoCmd)
  }
}

let nextHole = model => {
  let course = Terrain.generate(~hole=model.run.hole)
  let tee = teeOf(course)
  let shotId = model.shotId + 1
  // Throw the ball up out of the cup and back to the next tee. It rides the
  // same keyframe machinery a shot does, so it is a real parabola and it is
  // visible the whole way — the ball is painted under the terrain, so anything
  // that slides it along the ground would travel underground.
  let arc = Physics.hop(
    course,
    ~fromX=model.ball.x,
    ~fromY=model.ball.y,
    ~toX=tee.x,
    ~toY=tee.y,
    ~seconds=Int.toFloat(shiftMs) /. 1000.0 *. 0.92,
  )
  let program = Css.compile(arc, ~stageH=Terrain.worldH, ~id=shotId, ~spin0=model.spin)
  // The new course goes in immediately — the view transitions the clip-path
  // toward it rather than swapping — but the hole is not playable until the
  // dunes have finished moving.
  (
    {
      ...model,
      strokes: 0,
      course,
      ball: tee,
      phase: Shifting,
      program: Some(program),
      shotId,
      spin: program.spinEnd,
    },
    After(shiftMs, ShiftDone),
  )
}

let update = (model, msg) =>
  switch (msg, model.phase) {
  // A resize only changes how the world is projected. The course is generated
  // in fixed world units, so rotating the device no longer rebuilds it under
  // the ball.
  | (Rescaled(scale), _) => ({...model, scale}, NoCmd)
  | (ToastExpired, _) => ({...model, toast: None}, NoCmd)

  | (ToggledCheat, _) =>
    let run = {...model.run, cheat: !model.run.cheat}
    ({...model, run}, Persist(run))

  | (ResetPressed, _) =>
    if model.resetArmed {
      (
        fresh(~scale=model.scale, ~run=Score.empty, ~toast=Some("new run")),
        Batch([Forget, After(1800, ToastExpired)]),
      )
    } else {
      ({...model, resetArmed: true}, After(resetWindow, ResetDisarmed))
    }
  | (ResetDisarmed, _) => ({...model, resetArmed: false}, NoCmd)

  // Accepted while already aiming too: without pointer capture a pointerup can
  // in principle be missed, and this makes that a new aim rather than a lock.
  | (PointerDown(p), Ready)
  | (PointerDown(p), Aiming(_)) =>
    ({...model, phase: Aiming({from: p, to_: p}), toast: None}, NoCmd)
  | (PointerMoved(p), Aiming({from})) => ({...model, phase: Aiming({from, to_: p})}, NoCmd)
  | (PointerUp, Aiming({from, to_})) => launch(model, from, to_)
  | (PointerCancelled, Aiming(_)) => ({...model, phase: Ready}, NoCmd)

  | (ShotEnded, Watching(shot)) => settle(model, shot)
  | (AdvanceHole, Between) => nextHole(model)
  | (ShiftDone, Shifting) => ({...model, phase: Ready}, NoCmd)

  // Anything else is a message that does not apply to the current phase —
  // a stray pointer during flight, a late timer. Ignoring it is the whole
  // reason the phase is a variant.
  | _ => (model, NoCmd)
  }
