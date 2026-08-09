// The runtime: hold the model, feed messages through `update`, hand the result
// to `view`, and interpret the commands it returns.
//
// There is no requestAnimationFrame here, or anywhere in the project. The only
// clock is the browser's own animation engine, which reports back via
// animationend.

open Model

let stage = View.stage

let scaleFor = () => {
  let r = stage->Web.getBoundingClientRect
  // Fit the world's width exactly. The gameplay axis is horizontal, so the
  // whole hole is always visible; spare vertical space simply becomes more sky.
  r.width /. Terrain.worldW
}

// The saved run is read once, at boot. A missing or unreadable save just starts
// a new run rather than failing.
let restored = switch Web.read(Score.key) {
| Some(raw) => Score.decode(raw)->Option.getOr(Score.empty)
| None => Score.empty
}

let model = ref(init(~scale=scaleFor(), ~run=restored))

let rec perform = cmd =>
  switch cmd {
  | NoCmd => ()
  | Batch(cs) => Array.forEach(cs, perform)
  | After(ms, msg) => Web.setTimeout(() => dispatch(msg), ms)
  | Persist(run) => Web.write(Score.key, Score.encode(run))
  | Forget => Web.forget(Score.key)
  }

and dispatch = msg => {
  let (next, cmd) = Update.update(model.contents, msg)
  model := next
  View.sync(next)
  perform(cmd)
}

/** Client coordinates -> world coordinates, y up. */
let toWorld = (e: Web.pointerEvent) => {
  let r = stage->Web.getBoundingClientRect
  let s = model.contents.scale
  {x: (e.clientX -. r.left) /. s, y: (r.top +. r.height -. e.clientY) /. s}
}

let init = () => {
  View.sync(model.contents)

  // No setPointerCapture. #stage is position:fixed inset:0, so the pointer
  // cannot leave it anyway — and capturing made Chromium fire pointercancel
  // instead of pointerup on every gesture after the first, as soon as any
  // element was painted beneath #world. A capture we do not need is not worth
  // that. If a pointerup is ever missed, PointerDown restarts the aim rather
  // than the game soft-locking in Aiming.
  stage->Web.onPointer("pointerdown", e => dispatch(PointerDown(toWorld(e))))
  stage->Web.onPointer("pointermove", e => dispatch(PointerMoved(toWorld(e))))
  stage->Web.onPointer("pointerup", e => {
    dispatch(PointerMoved(toWorld(e)))
    dispatch(PointerUp)
  })
  stage->Web.onPointer("pointercancel", _ => dispatch(PointerCancelled))

  // The browser telling us the shot is over is the only frame signal in the game.
  View.ballX->Web.onAnimation("animationend", _ => dispatch(ShotEnded))

  View.cheatBtn->Web.onClick("click", () => dispatch(ToggledCheat))
  View.resetBtn->Web.onClick("click", () => dispatch(ResetPressed))

  // Rotating the device only changes how the world is projected — but the new
  // size has to be measured *after* the browser has actually adopted it. In an
  // installed iOS web app `resize` fires while the previous layout is still in
  // effect, so a single synchronous measurement leaves the world scaled for the
  // old orientation: the course is cropped and there is dead space around it,
  // and it stays that way until something else happens to fire a resize.
  //
  // Measuring again a beat later heals that without a render loop. `Rescaled`
  // only stores a number and the view diffs on it, so the extra measurements
  // that agree cost nothing. Everything — including `toWorld` — keeps measuring
  // the stage's own rect, so the projection and the pointer mapping can never
  // disagree about the size even while it is settling.
  let remeasure = () => {
    dispatch(Rescaled(scaleFor()))
    Web.setTimeout(() => dispatch(Rescaled(scaleFor())), 120)
    Web.setTimeout(() => dispatch(Rescaled(scaleFor())), 400)
  }
  Web.window->Web.onResize("resize", remeasure)
  Web.window->Web.onResize("orientationchange", remeasure)
  switch Web.visualViewport->Null.toOption {
  | Some(vv) => vv->Web.onViewport("resize", remeasure)
  | None => ()
  }
}

init()
