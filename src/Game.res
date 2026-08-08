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

let model = ref(init(~scale=scaleFor()))

let rec perform = cmd =>
  switch cmd {
  | NoCmd => ()
  | Batch(cs) => Array.forEach(cs, perform)
  | After(ms, msg) => Web.setTimeout(() => dispatch(msg), ms)
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

  stage->Web.onPointer("pointerdown", e => {
    stage->Web.setPointerCapture(e.pointerId)
    dispatch(PointerDown(toWorld(e)))
  })
  stage->Web.onPointer("pointermove", e => dispatch(PointerMoved(toWorld(e))))
  stage->Web.onPointer("pointerup", e => {
    dispatch(PointerMoved(toWorld(e)))
    dispatch(PointerUp)
  })
  stage->Web.onPointer("pointercancel", _ => dispatch(PointerCancelled))

  // The browser telling us the shot is over is the only frame signal in the game.
  View.ballX->Web.onAnimation("animationend", _ => dispatch(ShotEnded))

  View.cheatBtn->Web.onClick("click", () => dispatch(ToggledCheat))

  Web.window->Web.onResize("resize", () => dispatch(Rescaled(scaleFor())))
}

init()
