// The only module that touches the DOM.
//
// It is a function of the model, but it diffs against the previous model before
// writing, and that is correctness rather than optimisation: re-assigning
// `animation` on the ball *restarts the shot*. The view must not touch an
// animation property unless the shot itself changed.

open Model

let stage = Web.el("stage")
let world = Web.el("world")
let ground = Web.el("ground")
let crust = Web.el("crust")
let far1 = Web.el("far1")
let far2 = Web.el("far2")
let cup = Web.el("cup")
let flag = Web.el("flag")
let ballX = Web.el("ballX")
let ballY = Web.el("ballY")
let ball = Web.el("ball")
let shadowX = Web.el("shadowX")
let shadow = Web.el("shadow")
let aim = Web.el("aim")
let trail = Web.el("trail")
let cheatBtn = Web.el("cheat")
let shotStyle = Web.el("shotStyle")
let hudHole = Web.el("hudHole")
let hudStrokes = Web.el("hudStrokes")
let hudTotal = Web.el("hudTotal")
let hudAvg = Web.el("hudAvg")
let resetBtn = Web.el("reset")
let toastEl = Web.el("toast")

// Screen y within the world box grows downward; the model's y grows up.
let flip = wy => Terrain.worldH -. wy

// ------------------------------------------------------------------ terrain

let polygon = (ys, ~step) => {
  let pts = []
  Array.push(pts, `0px ${Web.px(Terrain.worldH)}`)
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    if x <= Terrain.worldW +. step {
      Array.push(pts, `${Web.px(Terrain.clamp(x, 0.0, Terrain.worldW))} ${Web.px(flip(y))}`)
    }
  })
  Array.push(pts, `${Web.px(Terrain.worldW)} ${Web.px(Terrain.worldH)}`)
  `polygon(${Array.join(pts, ",")})`
}

let drawCourse = (model: model) => {
  let t = model.course
  let clip = polygon(t.ys, ~step=t.step)
  ground->Web.set("clip-path", clip)
  crust->Web.set("clip-path", clip)
  far1->Web.set("clip-path", polygon(Terrain.backdrop(~hole=model.run.hole, ~layer=1), ~step=26.0))
  far2->Web.set("clip-path", polygon(Terrain.backdrop(~hole=model.run.hole, ~layer=0), ~step=26.0))

  cup->Web.set("left", Web.px(t.holeX -. Terrain.cupR))
  cup->Web.set("top", Web.px(flip(t.holeY) -. 3.0))
  cup->Web.set("width", Web.px(Terrain.cupR *. 2.0))
  flag->Web.set("left", Web.px(t.holeX))
  flag->Web.set("top", Web.px(flip(t.holeY)))
}

// --------------------------------------------------------------------- ball

/** Park the ball at its resting position with no animation attached. */
let placeBall = (model: model) => {
  ballX->Web.set("animation", "none")
  ballY->Web.set("animation", "none")
  ball->Web.set("animation", "none")
  shadowX->Web.set("animation", "none")
  shadow->Web.set("animation", "none")
  ballX->Web.set("left", Web.px(model.ball.x))
  ballY->Web.set("top", Web.px(flip(model.ball.y)))
  ball->Web.set("transform", `rotate(${Float.toFixed(model.spin, ~digits=2)}deg)`)
  shadowX->Web.set("left", Web.px(model.ball.x))
  shadow->Web.set("top", Web.px(flip(Terrain.heightAt(model.course, model.ball.x))))
  shadow->Web.set("opacity", "0.3")
  shadow->Web.set("scale", "1 0.55")
}

/** Hand the shot to the browser. From here it owns the ball until animationend. */
let startShot = (model: model, program: Css.program) => {
  shotStyle->Web.setText(program.css)
  // Keyframe offsets are relative to where the ball starts.
  ballX->Web.set("left", Web.px(model.ball.x))
  ballY->Web.set("top", Web.px(flip(model.ball.y)))
  shadowX->Web.set("left", Web.px(model.ball.x))
  shadow->Web.set("top", Web.px(flip(model.ball.y)))
  let d = Float.toFixed(program.duration, ~digits=4)
  ballX->Web.restart(`${program.nameX} ${d}s linear forwards`)
  ballY->Web.restart(`${program.nameY} ${d}s linear forwards`)
  ball->Web.restart(`${program.nameSpin} ${d}s linear forwards`)
  shadowX->Web.restart(`${program.nameX} ${d}s linear forwards`)
  shadow->Web.restart(
    `${program.nameShadow} ${d}s linear forwards, ${program.nameShadow}o ${d}s linear forwards`,
  )
}

// --------------------------------------------------------------- trajectory

let trailDots = 32

let dots = Array.fromInitializer(~length=trailDots, _ => {
  let d = Web.createElement("i")
  d->Web.setClassName("dot")
  trail->Web.appendChild(d)
  d
})

let hideTrail = () => trail->Web.set("opacity", "0")

/**
Draw the predicted path.

Runs the same `Physics.simulate` the real shot runs and reads positions back
with `Physics.sample`, which rebuilds each segment from the same constant
acceleration the keyframes encode — so these dots are not an estimate of the
shot, they are the shot.
*/
let showTrail = (model: model, ~vx, ~vy) => {
  let shot = Physics.simulate(model.course, ~x0=model.ball.x, ~y0=model.ball.y, ~vx0=vx, ~vy0=vy)

  // Walk the path finely, then place dots at even *distance* apart rather than
  // even time apart, which would smear them over the fast opening arc and pile
  // them into a blob wherever the ball is slow.
  let fine = 240
  let path = Array.fromInitializer(~length=fine + 1, i =>
    Physics.sample(shot.stops, Int.toFloat(i) /. Int.toFloat(fine) *. shot.duration)
  )
  let cum = Array.make(~length=fine + 1, 0.0)
  for i in 1 to fine {
    let (px, py) = Array.getUnsafe(path, i - 1)
    let (cx, cy) = Array.getUnsafe(path, i)
    let seg = Math.sqrt((cx -. px) *. (cx -. px) +. (cy -. py) *. (cy -. py))
    Array.setUnsafe(cum, i, Array.getUnsafe(cum, i - 1) +. seg)
  }
  let total = Array.getUnsafe(cum, fine)

  let last = trailDots - 1
  let cursor = ref(0)
  Array.forEachWithIndex(dots, (d, i) => {
    let f = Int.toFloat(i) /. Int.toFloat(last)
    let want = f *. total
    while cursor.contents < fine && Array.getUnsafe(cum, cursor.contents + 1) < want {
      cursor := cursor.contents + 1
    }
    let (x, y) = Array.getUnsafe(path, cursor.contents)
    d->Web.set("left", Web.px(x))
    d->Web.set("top", Web.px(flip(y)))
    d->Web.set("opacity", Float.toFixed(1.0 -. 0.55 *. f, ~digits=3))
  })
  // Tells you outright whether this drag holes out. That is the cheat.
  trail->Web.setClassName(shot.outcome == Physics.Sunk ? "trail sinks" : "trail")
  trail->Web.set("opacity", "1")
}

let showAim = (model: model, a: aim) => {
  let dx = a.from.x -. a.to_.x
  let dy = a.from.y -. a.to_.y
  let (vx, vy, power) = Update.aimVector(a.from, a.to_)
  // atan2 is in world space (y up); CSS rotation is clockwise from +x in screen
  // space (y down), hence the negated dy.
  let angle = Math.atan2(~y=-.dy, ~x=dx) *. 57.2958

  if model.run.cheat && power > 0.03 {
    showTrail(model, ~vx, ~vy)
  } else {
    hideTrail()
  }
  aim->Web.set("opacity", power > 0.03 ? "1" : "0")
  aim->Web.set("left", Web.px(model.ball.x))
  aim->Web.set("top", Web.px(flip(model.ball.y)))
  aim->Web.set("width", Web.px(18.0 +. power *. 122.0))
  aim->Web.set("transform", `rotate(${Float.toFixed(angle, ~digits=2)}deg)`)
  aim->Web.set("--power", Float.toFixed(power, ~digits=3))
}

let hideAim = () => {
  aim->Web.set("opacity", "0")
  hideTrail()
}

// --------------------------------------------------------------------- sync

let previous: ref<option<model>> = ref(None)

let sync = (model: model) => {
  let prev = previous.contents
  previous := Some(model)

  let first = prev == None
  let changed = f =>
    switch prev {
    | None => true
    | Some(p) => f(p) != f(model)
    }

  if first || changed(m => m.scale) {
    world->Web.set("transform", `scale(${Float.toFixed(model.scale, ~digits=5)})`)
  }

  // The shifting class must be on before the new clip-path is written, or the
  // terrain snaps instead of morphing.
  if first || changed(m => isShifting(m)) {
    stage->Web.setClassName(isShifting(model) ? "stage shifting" : "stage")
  }

  if needsRedraw(prev, model) {
    drawCourse(model)
    // Wind is a property of the hole. Publishing it as two custom properties
    // lets the flag and the blowing sand read it declaratively, instead of the
    // view reaching into every element that cares.
    stage->Web.set(
      "--wind",
      Float.toFixed(Math.abs(model.course.wind) /. Terrain.windMax, ~digits=3),
    )
    stage->Web.set("--wind-dir", model.course.wind >= 0.0 ? "1" : "-1")
  }

  // The one write that must be conditional: starting a shot.
  let startedShot = changed(m => m.shotId) && isWatching(model)
  switch (startedShot, model.program) {
  | (true, Some(program)) => startShot(model, program)
  | _ => ()
  }

  // Static placement, only when the ball is not under the browser's control and
  // something about its resting state actually moved.
  let leftWatching =
    switch prev {
    | Some(p) => isWatching(p) && !isWatching(model)
    | None => false
    }
  if !isWatching(model) && (first || leftWatching || changed(m => m.ball) || changed(m => m.spin)) {
    placeBall(model)
  }

  switch model.phase {
  | Aiming(a) => showAim(model, a)
  | _ => if first || changed(m => m.phase) { hideAim() }
  }

  if first || changed(m => m.run.hole) {
    hudHole->Web.setText(Int.toString(model.run.hole))
  }
  if first || changed(m => m.strokes) {
    hudStrokes->Web.setText(Int.toString(model.strokes))
  }
  if first || changed(m => m.run.total) {
    hudTotal->Web.setText(Int.toString(model.run.total))
  }
  // Average strokes per completed hole: the score that actually means something
  // on a course with no par and no end.
  if first || changed(m => m.run.total) || changed(m => m.run.hole) {
    hudAvg->Web.setText(
      switch Score.average(model.run) {
      | Some(a) => Float.toFixed(a, ~digits=2)
      | None => "—"
      },
    )
  }

  if first || changed(m => m.run.cheat) {
    cheatBtn->Web.setAttribute("aria-pressed", model.run.cheat ? "true" : "false")
  }
  if first || changed(m => m.resetArmed) {
    resetBtn->Web.setText(model.resetArmed ? "tap again" : "new run")
    resetBtn->Web.setAttribute("aria-pressed", model.resetArmed ? "true" : "false")
  }

  if first || changed(m => m.toast) {
    switch model.toast {
    | Some(text) =>
      toastEl->Web.setText(text)
      toastEl->Web.set("opacity", "1")
    | None => toastEl->Web.set("opacity", "0")
    }
  }
}
