// Hand-rolled externals. The surface this game needs is small: find elements,
// set styles, listen for pointer and animationend. No render loop lives here.

type element
type style
type window
type rect = {width: float, height: float, left: float, top: float}

@val @scope("document") external byId: string => Null.t<element> = "getElementById"
@get external style: element => style = "style"
@set external setText: (element, string) => unit = "textContent"
@send external getBoundingClientRect: element => rect = "getBoundingClientRect"
@send external setProperty: (style, string, string) => unit = "setProperty"
@get external offsetWidth: element => float = "offsetWidth"

type pointerEvent = {clientX: float, clientY: float, pointerId: int}
type animationEvent = {animationName: string}

@val @scope("document") external createElement: string => element = "createElement"
@send external appendChild: (element, element) => unit = "appendChild"
@set external setClassName: (element, string) => unit = "className"
@send external setAttribute: (element, string, string) => unit = "setAttribute"

@send external onPointer: (element, string, pointerEvent => unit) => unit = "addEventListener"
@send external onClick: (element, string, unit => unit) => unit = "addEventListener"
@send external onAnimation: (element, string, animationEvent => unit) => unit = "addEventListener"
@send external onResize: (window, string, unit => unit) => unit = "addEventListener"

@val external window: window = "window"
@val external setTimeout: (unit => unit, int) => unit = "setTimeout"

// The visual viewport is the one that reports a new size first during an
// orientation change, and it is absent on older Safari, so it is an option.
type viewport
@val external visualViewport: Null.t<viewport> = "visualViewport"
@send external onViewport: (viewport, string, unit => unit) => unit = "addEventListener"

let el = id =>
  switch byId(id)->Null.toOption {
  | Some(e) => e
  | None => panic(`missing element #${id}`)
  }

let set = (e, prop, value) => e->style->setProperty(prop, value)
let px = (v: float) => Float.toFixed(v, ~digits=2) ++ "px"

// Restart an animation that may already be running: clearing it and reading
// layout forces the browser to treat the next assignment as a fresh animation.
let restart = (e, value) => {
  e->set("animation", "none")
  let _ = e->offsetWidth
  e->set("animation", value)
}

// localStorage. Both calls are wrapped by callers because Safari throws on
// setItem in private browsing rather than failing quietly.
@val @scope("localStorage") external getItem: string => Null.t<string> = "getItem"
@val @scope("localStorage") external setItem: (string, string) => unit = "setItem"
@val @scope("localStorage") external removeItem: string => unit = "removeItem"

let read = key =>
  try getItem(key)->Null.toOption catch {
  | _ => None
  }

let write = (key, value) =>
  try setItem(key, value) catch {
  | _ => ()
  }

let forget = key =>
  try removeItem(key) catch {
  | _ => ()
  }
