// Glue. Everything here is event-driven: pointer down/move/up, and animationend.
// There is no requestAnimationFrame in this file, or anywhere in the project.

type phase = Ready | Aiming | Rolling | Between

let maxDrag = 190.0
let maxSpeed = 1280.0

let stage = Web.el("stage")
let ground = Web.el("ground")
let crust = Web.el("crust")
let far1 = Web.el("far1")
let far2 = Web.el("far2")
let cup = Web.el("cup")
let flag = Web.el("flag")
let ballX = Web.el("ballX")
let ballY = Web.el("ballY")
let ball = Web.el("ball")
// The shadow rides its own X wrapper rather than living inside the ball, so it
// can sit *above* the terrain in z-order while the ball sits below it.
let shadowX = Web.el("shadowX")
let shadow = Web.el("shadow")
let aim = Web.el("aim")
let shotStyle = Web.el("shotStyle")
let hudHole = Web.el("hudHole")
let hudStrokes = Web.el("hudStrokes")
let hudTotal = Web.el("hudTotal")
let toast = Web.el("toast")

let width = ref(1000.0)
let height = ref(600.0)
let course = ref(Terrain.generate(~seed=1, ~width=1000.0, ~height=600.0))
let holeNo = ref(1)
let strokes = ref(0)
let total = ref(0)
let shotId = ref(0)
let phase = ref(Ready)
let bx = ref(0.0)
let by = ref(0.0)
let dragFrom = ref((0.0, 0.0))
let dragTo = ref((0.0, 0.0))
let spin = ref(0.0)

let screenY = wy => height.contents -. wy

// ---------------------------------------------------------------- rendering

let polygon = (ys, ~step, ~w, ~h) => {
  let pts = []
  Array.push(pts, `0px ${Web.px(h)}`)
  Array.forEachWithIndex(ys, (y, i) => {
    let x = Int.toFloat(i) *. step
    if x <= w +. step {
      Array.push(pts, `${Web.px(Terrain.clamp(x, 0.0, w))} ${Web.px(h -. y)}`)
    }
  })
  Array.push(pts, `${Web.px(w)} ${Web.px(h)}`)
  `polygon(${Array.join(pts, ",")})`
}

let drawCourse = () => {
  let t = course.contents
  let (w, h) = (width.contents, height.contents)
  let clip = polygon(t.ys, ~step=t.step, ~w, ~h)
  ground->Web.set("clip-path", clip)
  crust->Web.set("clip-path", clip)

  far1->Web.set(
    "clip-path",
    polygon(Terrain.backdrop(~seed=holeNo.contents, ~width=w, ~height=h, ~layer=1), ~step=26.0, ~w, ~h),
  )
  far2->Web.set(
    "clip-path",
    polygon(Terrain.backdrop(~seed=holeNo.contents, ~width=w, ~height=h, ~layer=0), ~step=26.0, ~w, ~h),
  )

  cup->Web.set("left", Web.px(t.holeX -. Terrain.cupR))
  cup->Web.set("top", Web.px(screenY(t.holeY) -. 3.0))
  cup->Web.set("width", Web.px(Terrain.cupR *. 2.0))

  flag->Web.set("left", Web.px(t.holeX))
  flag->Web.set("top", Web.px(screenY(t.holeY)))
}

// Park the ball at a resting world position with no animation attached.
// Rotation is carried over as an inline transform so the ball never snaps back
// to 0deg between shots.
let placeBall = (x, y) => {
  bx := x
  by := y
  ballX->Web.set("animation", "none")
  ballY->Web.set("animation", "none")
  ball->Web.set("animation", "none")
  shadowX->Web.set("animation", "none")
  shadow->Web.set("animation", "none")
  ballX->Web.set("left", Web.px(x))
  ballY->Web.set("top", Web.px(screenY(y)))
  ball->Web.set("transform", `rotate(${Float.toFixed(spin.contents, ~digits=2)}deg)`)
  shadowX->Web.set("left", Web.px(x))
  shadow->Web.set("top", Web.px(screenY(Terrain.heightAt(course.contents, x))))
  shadow->Web.set("opacity", "0.3")
  shadow->Web.set("scale", "1 0.55")
}

let hud = () => {
  hudHole->Web.setText(Int.toString(holeNo.contents))
  hudStrokes->Web.setText(Int.toString(strokes.contents))
  hudTotal->Web.setText(Int.toString(total.contents))
}

let say = (msg, ms) => {
  toast->Web.setText(msg)
  toast->Web.set("opacity", "1")
  Web.setTimeout(() => toast->Web.set("opacity", "0"), ms)
}

// ---------------------------------------------------------------- the shot

let settle = (shot: Physics.shot) => {
  // Write the resting position before clearing the animation, so nothing
  // repaints in between and the ball never jumps.
  placeBall(shot.endX, shot.endY)

  switch shot.outcome {
  | Physics.Sunk =>
    phase := Between
    total := total.contents + strokes.contents
    let s = strokes.contents
    say(s == 1 ? "hole in one" : `sunk in ${Int.toString(s)}`, 1400)
    hud()
    Web.setTimeout(() => {
      holeNo := holeNo.contents + 1
      strokes := 0
      let t = Terrain.generate(~seed=holeNo.contents, ~width=width.contents, ~height=height.contents)
      course := t
      drawCourse()
      placeBall(t.teeX, t.teeY +. Physics.ballR)
      hud()
      phase := Ready
    }, 900)
  | Physics.Rest => phase := Ready
  }
}

let pending = ref(None)

let shoot = (~vx, ~vy) => {
  let shot = Physics.simulate(course.contents, ~x0=bx.contents, ~y0=by.contents, ~vx0=vx, ~vy0=vy)
  shotId := shotId.contents + 1
  let prog = Css.compile(shot, ~stageH=height.contents, ~id=shotId.contents, ~spin0=spin.contents)

  strokes := strokes.contents + 1
  hud()
  spin := prog.spinEnd

  if prog.duration < 0.05 {
    settle(shot)
  } else {
    shotStyle->Web.setText(prog.css)

    // Anchor: keyframe offsets are relative to where the ball starts.
    ballX->Web.set("left", Web.px(bx.contents))
    ballY->Web.set("top", Web.px(screenY(by.contents)))
    shadowX->Web.set("left", Web.px(bx.contents))
    shadow->Web.set("top", Web.px(screenY(by.contents)))

    let d = Float.toFixed(prog.duration, ~digits=4)
    phase := Rolling
    pending := Some(shot)

    // Four elements, one shared timeline. From here the browser owns the shot.
    ballX->Web.restart(`${prog.nameX} ${d}s linear forwards`)
    ballY->Web.restart(`${prog.nameY} ${d}s linear forwards`)
    ball->Web.restart(`${prog.nameSpin} ${d}s linear forwards`)
    shadowX->Web.restart(`${prog.nameX} ${d}s linear forwards`)
    shadow->Web.restart(
      `${prog.nameShadow} ${d}s linear forwards, ${prog.nameShadow}o ${d}s linear forwards`,
    )
  }
}

// ---------------------------------------------------------------- aiming

let showAim = () => {
  let (sx, sy) = dragFrom.contents
  let (cx, cy) = dragTo.contents
  let dx = sx -. cx
  let dy = sy -. cy
  let len = Math.sqrt(dx *. dx +. dy *. dy)
  let power = Terrain.clamp(len /. maxDrag, 0.0, 1.0)
  let angle = Math.atan2(~y=dy, ~x=dx) *. 57.2958

  aim->Web.set("opacity", power > 0.03 ? "1" : "0")
  aim->Web.set("left", Web.px(bx.contents))
  aim->Web.set("top", Web.px(screenY(by.contents)))
  aim->Web.set("width", Web.px(18.0 +. power *. 122.0))
  aim->Web.set("transform", `rotate(${Float.toFixed(angle, ~digits=2)}deg)`)
  aim->Web.set("--power", Float.toFixed(power, ~digits=3))
  power
}

let release = () => {
  let power = showAim()
  aim->Web.set("opacity", "0")
  if power > 0.06 {
    let (sx, sy) = dragFrom.contents
    let (cx, cy) = dragTo.contents
    let dx = sx -. cx
    let dy = sy -. cy
    let len = Math.max(Math.sqrt(dx *. dx +. dy *. dy), 0.0001)
    let speed = power *. maxSpeed
    shoot(~vx=dx /. len *. speed, ~vy=-.(dy /. len) *. speed)
  } else {
    phase := Ready
  }
}

// ---------------------------------------------------------------- lifecycle

let layout = () => {
  let r = stage->Web.getBoundingClientRect
  width := r.width
  height := r.height
  course := Terrain.generate(~seed=holeNo.contents, ~width=r.width, ~height=r.height)
  drawCourse()
  let t = course.contents
  placeBall(t.teeX, t.teeY +. Physics.ballR)
  hud()
  phase := Ready
}

let local = (e: Web.pointerEvent) => {
  let r = stage->Web.getBoundingClientRect
  (e.clientX -. r.left, e.clientY -. r.top)
}

let init = () => {
  layout()

  stage->Web.onPointer("pointerdown", e => {
    if phase.contents == Ready {
      phase := Aiming
      dragFrom := local(e)
      dragTo := local(e)
      stage->Web.setPointerCapture(e.pointerId)
      let _ = showAim()
    }
  })

  stage->Web.onPointer("pointermove", e =>
    if phase.contents == Aiming {
      dragTo := local(e)
      let _ = showAim()
    }
  )

  stage->Web.onPointer("pointerup", e => {
    if phase.contents == Aiming {
      dragTo := local(e)
      release()
    }
  })

  stage->Web.onPointer("pointercancel", _ => {
    if phase.contents == Aiming {
      aim->Web.set("opacity", "0")
      phase := Ready
    }
  })

  // The only "frame" signal in the game: the browser telling us the shot ended.
  ballX->Web.onAnimation("animationend", _ =>
    switch pending.contents {
    | Some(shot) if phase.contents == Rolling =>
      pending := None
      settle(shot)
    | _ => ()
    }
  )

  Web.window->Web.onResize("resize", () =>
    if phase.contents == Ready || phase.contents == Aiming {
      layout()
    }
  )

  say("drag back from the ball, then let go", 3200)
}

init()
