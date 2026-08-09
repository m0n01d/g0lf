// Everything that can only be checked in a real browser, in one command.
//
// Every check here exists because something shipped broken. Run `npm run check`
// before saying a change works. It builds, serves the *production* bundle, and
// drives it.
//
//   node test/browser.mjs                     # builds + serves dist itself
//   node test/browser.mjs https://m0n01d.github.io/g0lf/   # checks the live site
import { chromium } from "playwright"
import { PNG } from "pngjs"
import { spawn } from "child_process"
import fs from "fs"

// -------------------------------------------------------------- harness bits

let pass = 0, fail = 0
const failures = []
const ok = (name, cond, detail = "") => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; failures.push(name); console.log("  FAIL " + name + (detail ? "\n         " + detail : "")) }
}

// Playwright's bundled revision may not match a preinstalled browser, so find
// one rather than assuming. Falls back to Playwright's own download.
const chromePath = () => {
  if (process.env.G0LF_CHROME) return process.env.G0LF_CHROME
  for (const dir of ["/opt/pw-browsers"]) {
    if (!fs.existsSync(dir)) continue
    for (const e of fs.readdirSync(dir)) {
      const p = `${dir}/${e}/chrome-linux/chrome`
      if (fs.existsSync(p)) return p
    }
  }
  return undefined
}

const target = process.argv[2]
let server
const baseUrl = await (async () => {
  if (target) return target.endsWith("/") ? target : target + "/"
  server = spawn("npx", ["vite", "preview", "--port", "4178", "--host", "127.0.0.1"],
    { stdio: "ignore", detached: false })
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch("http://127.0.0.1:4178/g0lf/")
      if (r.ok) break
    } catch {}
    await new Promise(r => setTimeout(r, 250))
  }
  return "http://127.0.0.1:4178/g0lf/"
})()
const stop = () => { if (server) try { server.kill("SIGKILL") } catch {} }

const browser = await chromium.launch({ executablePath: chromePath() })
const errors = []
const newPage = async (opts = {}) => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 600 }, ...opts })
  const p = await ctx.newPage()
  p.on("pageerror", e => errors.push("PAGEERROR " + e.message))
  p.on("console", m => { if (m.type() === "error") errors.push("console.error " + m.text()) })
  await p.goto(baseUrl, { waitUntil: "networkidle" })
  await p.evaluate(() => localStorage.removeItem("g0lf.run.v1"))
  await p.reload({ waitUntil: "networkidle" })
  await p.waitForTimeout(350)
  return p
}

// The solver needs the real modules. In a production build they are bundled, so
// re-derive what we need from the page instead: read the cup position the game
// itself rendered, and aim by bisection on the visible outcome.
const hud = p => p.evaluate(() => ({
  hole: +document.getElementById("hudHole").textContent,
  strokes: +document.getElementById("hudStrokes").textContent,
  total: +document.getElementById("hudTotal").textContent,
  avg: document.getElementById("hudAvg").textContent,
  ballX: parseFloat(document.getElementById("ballX").style.left),
  ballY: parseFloat(document.getElementById("ballY").style.top),
  cupLeft: document.getElementById("cup").style.left,
  flagLeft: document.getElementById("flag").style.left,
  clip: getComputedStyle(document.getElementById("ground")).clipPath.length,
  scale: document.getElementById("world").style.transform,
  saved: localStorage.getItem("g0lf.run.v1"),
}))

const drag = async (p, fromX, fromY, dx, dy) => {
  await p.mouse.move(fromX, fromY)
  await p.mouse.down()
  await p.mouse.move(fromX + dx, fromY + dy, { steps: 8 })
  await p.mouse.up()
}
const settle = (p, ms = 3600) => p.waitForTimeout(ms)
const phaseAcceptsInput = strokes => strokes === "0"

// Sink the current hole deterministically, by sweeping an aim while holding the
// pointer down and watching the game's own "this drag holes out" marker. That
// is far more reliable than guessing angles, and it doubles as a check that the
// prediction is real. Returns false without costing a stroke if none is found.
const aimUntilSinks = async (p, cx = 450, cy = 300) => {
  const pressed = await p.getAttribute("#cheat", "aria-pressed")
  if (pressed !== "true") await p.click("#cheat")
  await p.mouse.move(cx, cy)
  await p.mouse.down()
  for (let a = -10; a <= 190; a += 6) {
    for (const len of [170, 140, 110, 80]) {
      const r = a * Math.PI / 180
      await p.mouse.move(cx - Math.cos(r) * len, cy + Math.sin(r) * len)
      await p.waitForTimeout(18)
      const cls = await p.getAttribute("#trail", "class")
      if (cls && cls.includes("sinks")) { await p.mouse.up(); return true }
    }
  }
  await p.mouse.move(cx, cy)   // back to zero power: releasing here costs nothing
  await p.mouse.up()
  return false
}


console.log(`\nchecking ${baseUrl}\n`)

// ------------------------------------------------------------------- 1. boot
{
  const p = await newPage()
  const s = await hud(p)
  ok("boots on hole 1 with a course drawn", s.hole === 1 && s.clip > 200, JSON.stringify(s.clip))
  ok("world is scaled to the viewport", /scale\(0\.9/.test(s.scale), s.scale)
  ok("ball is placed", s.ballX > 0 && s.ballY > 0)
  ok("page does not scroll horizontally",
    await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth))
  await p.context().close()
}

// ------------------------------------------- 2. input works repeatedly
// Regression: setPointerCapture made Chromium send pointercancel instead of
// pointerup on every gesture after the first, so only one shot per session fired.
{
  const p = await newPage()
  let cancels = 0
  await p.evaluate(() => { window.__c = 0; addEventListener("pointercancel", () => window.__c++, true) })
  const strokes = []
  for (let i = 0; i < 5; i++) {
    await drag(p, 450, 300, -110, 80)
    await settle(p, 3200)
    strokes.push((await hud(p)).strokes)
  }
  cancels = await p.evaluate(() => window.__c)
  ok("five drags in a row all register a shot",
    strokes.every((v, i) => v > 0 || i > 0), JSON.stringify(strokes))
  ok("no pointercancel during normal play", cancels === 0, "cancels=" + cancels)
  await p.context().close()
}

// --------------------------------------- 3. the terrain redraws per hole
// Regression: the view keyed its redraw on run.hole, which changes a message
// earlier than the course, leaving the DOM one hole behind. This walks three
// real holes and checks the rendered cup, flag and terrain all move each time.
{
  const p = await newPage()
  const seen = []
  for (let i = 0; i < 3; i++) {
    const s = await hud(p)
    seen.push({ hole: s.hole, cup: s.cupLeft, flag: s.flagLeft, clip: s.clip })
    if (i === 2) break
    const sank = await aimUntilSinks(p)
    ok(`hole ${s.hole} could be sunk`, sank)
    if (!sank) break
    await settle(p, 4200)
    ok(`hole ${s.hole} advanced the counter`, (await hud(p)).hole === s.hole + 1)
  }
  ok("three consecutive holes were reached", seen.length === 3, JSON.stringify(seen.map(s => s.hole)))
  ok("the cup is in a different place on every hole",
    new Set(seen.map(s => s.cup)).size === seen.length, JSON.stringify(seen.map(s => s.cup)))
  ok("the flag moves with the cup on every hole",
    new Set(seen.map(s => s.flag)).size === seen.length, JSON.stringify(seen.map(s => s.flag)))
  ok("the terrain polygon changes on every hole",
    new Set(seen.map(s => s.clip)).size === seen.length, JSON.stringify(seen.map(s => s.clip)))
  await p.context().close()
}

// ------------------------------ 3b. the next hole morphs, it does not snap
// The dunes reshape into the next hole: every course has the same number of
// polygon points, so clip-path interpolates. Measured at a steady 60fps.
{
  const p = await newPage()
  const read = () => p.evaluate(() => ({
    clip: getComputedStyle(document.getElementById("ground")).clipPath,
    shifting: document.getElementById("stage").className.includes("shifting"),
    sand: parseFloat(getComputedStyle(document.querySelector(".sand")).opacity),
  }))
  const ballBox = () => p.evaluate(() => {
    const r = document.getElementById("ball").getBoundingClientRect()
    return { y: Math.round(r.top + r.height / 2), x: Math.round(r.left + r.width / 2) }
  })
  // Where the ball is, and how many of its own pixels are actually painted there.
  //
  // "Visible" has to be checked by looking, not by comparing to the ground
  // element's box — #ground is a full-size div with a clip-path, so its bounding
  // rect is the element, not the dunes.
  //
  // The freeze is not decoration. The rect and the screenshot are two separate
  // round-trips and a screenshot costs ~220ms, during which the ball travels
  // ~115px — measured. Cropping the first rect out of the second frame lands on
  // empty sky and reads as "the ball is not there".
  const frozenBall = async () => {
    const box = await p.evaluate(() => {
      window.__held = document.getAnimations().filter(a => a.playState === "running")
      window.__held.forEach(a => a.pause())
      const r = document.getElementById("ball").getBoundingClientRect()
      return { y: Math.round(r.top + r.height / 2), x: Math.round(r.left + r.width / 2) }
    })
    const clip = {
      x: Math.max(0, box.x - 28), y: Math.max(0, box.y - 28),
      width: 56, height: 56,
    }
    const png = PNG.sync.read(await p.screenshot({ clip }))
    await p.evaluate(() => { window.__held.forEach(a => a.play()); window.__held = null })
    let n = 0
    for (let i = 0; i < png.data.length; i += 4)
      if (png.data[i] > 200 && png.data[i + 1] > 195 && png.data[i + 2] > 180) n++
    return { ...box, pixels: n }
  }
  const calmSand = (await read()).sand
  ok("a hole can be sunk to start the shift", await aimUntilSinks(p))

  // Wait for the shift to begin rather than guessing at the timing.
  await p.waitForFunction(
    () => document.getElementById("stage").className.includes("shifting"),
    null, { timeout: 20000 })
  const start = await read()
  const ballStart = await ballBox()
  // Halfway through the shift the ball should be at the top of its arc, well
  // above where it started and where it lands. Sliding it along the ground
  // would leave it underneath the terrain and invisible the whole way.
  await p.waitForTimeout(430)
  const ballMid = await frozenBall()
  await p.waitForTimeout(190)   // past the 0.55s surge ramp, still inside the shift
  const mid = await read()
  await p.waitForFunction(
    () => !document.getElementById("stage").className.includes("shifting"),
    null, { timeout: 20000 })
  await p.waitForTimeout(1000)  // let the surge decay fully before reading
  const end = await read()

  ok("the shift is a real phase the view knows about", start.shifting && !end.shifting)
  ok("the terrain ends up somewhere different", start.clip !== end.clip)
  ok("mid-shift is a genuine in-between, not a snap",
    mid.clip !== start.clip && mid.clip !== end.clip)
  ok("the wind gets up while the desert rearranges",
    mid.sand > calmSand && mid.sand > end.sand,
    `calm ${calmSand} -> mid ${mid.sand} -> settled ${end.sand}`)
  const ballEnd = await ballBox()
  ok("the ball is thrown well above both ends of its journey, not slid",
    ballMid.y < ballStart.y - 60 && ballMid.y < ballEnd.y - 60,
    `start y=${ballStart.y}  mid y=${ballMid.y}  end y=${ballEnd.y}`)
  ok("the ball is actually on screen mid-arc, not hidden under the terrain",
    ballMid.pixels >= 40, `only ${ballMid.pixels} bright px where the ball should be`)
  ok("the ball actually travels across to the new tee",
    Math.abs(ballEnd.x - ballStart.x) > 80, `${ballStart.x} -> ${ballEnd.x}`)
  ok("the hole is playable again once the dunes stop",
    phaseAcceptsInput(await p.evaluate(() => document.getElementById("hudStrokes").textContent)))
  await p.context().close()
}

// -------------------------------------------------- 4. scoring persists
{
  const p = await newPage()
  ok("a hole can be sunk to score", await aimUntilSinks(p))
  await settle(p, 4200)
  const after = await hud(p)
  ok("sinking advances the hole", after.hole === 2, JSON.stringify(after))
  ok("sinking writes a save", typeof after.saved === "string" && after.saved.startsWith("1|"),
    String(after.saved))
  ok("an average appears once a hole is done", after.avg !== "—", after.avg)

  await p.reload({ waitUntil: "networkidle" })   // as if the app had been closed
  await p.waitForTimeout(500)
  const resumed = await hud(p)
  ok("reopening resumes the run", resumed.hole === after.hole && resumed.total === after.total,
    JSON.stringify(resumed))

  await p.click("#reset")
  const armed = await p.evaluate(() => document.getElementById("reset").textContent.trim())
  ok("reset arms on the first press", /again/i.test(armed), armed)
  ok("reset does not wipe on the first press", (await hud(p)).hole === after.hole)
  await p.click("#reset")
  await p.waitForTimeout(400)
  const wiped = await hud(p)
  ok("reset wipes on the second press", wiped.hole === 1 && wiped.total === 0 && !wiped.saved,
    JSON.stringify(wiped))
  await p.context().close()
}

// ------------------------------------- 5. trajectory preview is truthful
{
  const p = await newPage()
  await p.click("#cheat")
  await p.mouse.move(450, 300)
  await p.mouse.down()
  await p.mouse.move(330, 380, { steps: 10 })
  await p.waitForTimeout(200)
  const predicted = await p.evaluate(() => {
    const d = [...document.querySelectorAll("#trail i")]
    return { n: d.length, x: parseFloat(d.at(-1).style.left), y: parseFloat(d.at(-1).style.top),
      visible: getComputedStyle(document.getElementById("trail")).opacity }
  })
  ok("the trajectory is drawn while aiming with the cheat on",
    predicted.n === 32 && predicted.visible === "1", JSON.stringify(predicted))
  await p.mouse.up()
  await settle(p, 4200)
  const actual = await hud(p)
  const dx = Math.abs(actual.ballX - predicted.x), dy = Math.abs(actual.ballY - predicted.y)
  ok("the predicted resting point matches where the ball stops (<1px)",
    dx < 1 && dy < 1, `dx=${dx.toFixed(2)} dy=${dy.toFixed(2)}`)
  await p.context().close()
}

// -------------------------- 5b. the preview draws the still-air path only
// The cheat shows the ideal line and says nothing about the wind — that is the
// game. Check 5 above runs on hole 1, which is dead calm, and pins the two
// together to under a pixel. Here the wind is 61% of maximum, and the dots must
// visibly disagree with where the ball actually ends up.
{
  const p = await newPage()
  await p.evaluate(() => localStorage.setItem("g0lf.run.v1", "1|36|0|0|0|0|1"))
  await p.reload({ waitUntil: "networkidle" })
  await p.waitForTimeout(400)
  ok("resumed on a windy hole", (await hud(p)).hole === 36)
  const wind = await p.evaluate(() =>
    parseFloat(getComputedStyle(document.getElementById("stage")).getPropertyValue("--wind")))
  ok("the hole really is windy", wind > 0.5, "--wind=" + wind)

  // Pull down-left to launch up-right, hard enough to spend real time airborne.
  await p.mouse.move(450, 300)
  await p.mouse.down()
  await p.mouse.move(375, 394, { steps: 10 })
  await p.waitForTimeout(200)
  const predicted = await p.evaluate(() => {
    const d = [...document.querySelectorAll("#trail i")].at(-1)
    return { x: parseFloat(d.style.left), y: parseFloat(d.style.top) }
  })
  await p.mouse.up()
  await settle(p, 4600)
  const landed = await hud(p)
  const drift = Math.abs(landed.ballX - predicted.x)
  ok("the wind pushes the ball off the previewed line (>25px)",
    drift > 25, `predicted x=${predicted.x.toFixed(1)} actual x=${landed.ballX.toFixed(1)}`)
  await p.context().close()
}

// -------------------------------------------- 6. the sky actually moves
// Regression: the first version was too subtle to perceive at all.
{
  const p = await newPage()
  // The near band's blobs sit at ~78-90% of a 468px layer, i.e. below y=350.
  // Clipping higher than that silently excluded it from the comparison.
  const sky = { x: 0, y: 0, width: 900, height: 430 }
  const at = async ms => {
    await p.evaluate(t => { for (const a of document.getAnimations()) { a.pause(); a.currentTime = t } }, ms)
    await p.waitForTimeout(90)
    return p.screenshot({ clip: sky })
  }
  const delta = (a, b) => {
    const A = PNG.sync.read(a), B = PNG.sync.read(b)
    let over = 0
    for (let i = 0; i < A.data.length; i += 4) {
      const d = Math.max(Math.abs(A.data[i] - B.data[i]), Math.abs(A.data[i + 1] - B.data[i + 1]),
        Math.abs(A.data[i + 2] - B.data[i + 2]))
      if (d >= 4) over++
    }
    return 100 * over / (A.data.length / 4)
  }
  const base = await at(0)
  const moved5 = delta(base, await at(5000))
  ok("the sky visibly changes within five seconds (>10% of pixels)",
    moved5 > 10, `only ${moved5.toFixed(1)}% moved`)

  // each cloud band must loop without a seam, at whatever duration it now has
  const bands = await p.evaluate(() => [...document.querySelectorAll(".clouds")].map(e => [
    [...e.classList].find(c => c !== "clouds"),
    parseFloat(getComputedStyle(e).animationDuration) * 1000]))
  ok("there are cloud bands to check", bands.length === 3, JSON.stringify(bands))
  for (const [cls, dur] of bands) {
    // Hide the world entirely so only the band under test can differ.
    await p.evaluate(only => {
      document.getElementById("world").style.visibility = "hidden"
      // Birds too: one crossing the frame at only one of the two sampled
      // times made a band look like it had a seam when it did not.
      for (const el of document.querySelectorAll(".clouds, .stars, .bird"))
        el.style.visibility = el.classList.contains(only) ? "visible" : "hidden"
    }, cls)
    const a0 = await at(0), aD = await at(dur), aH = await at(dur / 2)
    ok(`${cls} loops seamlessly and moves`,
      Buffer.compare(a0, aD) === 0 && Buffer.compare(a0, aH) !== 0)
  }
  await p.context().close()
}

// ------------------------------- 6b. stars, flag wind and birds
{
  const p = await newPage()
  const freeze = ms => p.evaluate(t => {
    for (const a of document.getAnimations()) { a.pause(); a.currentTime = t }
  }, ms)
  // Clip below the HUD and above the sun/terrain, so only sky is measured.
  const band = { x: 0, y: 95, width: 900, height: 160 }
  const brightPixels = async ms => {
    await freeze(ms); await p.waitForTimeout(80)
    const png = PNG.sync.read(await p.screenshot({ clip: band }))
    let n = 0
    for (let i = 0; i < png.data.length; i += 4)
      if (png.data[i] > 200 && png.data[i + 1] > 195 && png.data[i + 2] > 185) n++
    return n
  }
  // Stars must be big and bright enough to actually register as points of light.
  const peak = Math.max(await brightPixels(0), await brightPixels(2400), await brightPixels(4400))
  ok("stars are bright enough to read as stars (>=60 near-white px)", peak >= 60, "peak=" + peak)

  // ...and must visibly change brightness over a couple of seconds.
  const lo = await brightPixels(0), hi = await brightPixels(3200)
  ok("stars visibly twinkle within ~3s", Math.abs(hi - lo) >= 12, `${lo} -> ${hi}`)

  // The sky as a whole must now move perceptibly in three seconds, not five.
  const shot = async ms => { await freeze(ms); await p.waitForTimeout(80)
    return p.screenshot({ clip: { x: 0, y: 0, width: 900, height: 430 } }) }
  const a = PNG.sync.read(await shot(0)), b2 = PNG.sync.read(await shot(3000))
  let over = 0
  for (let i = 0; i < a.data.length; i += 4) {
    const d = Math.max(Math.abs(a.data[i] - b2.data[i]), Math.abs(a.data[i + 1] - b2.data[i + 1]),
      Math.abs(a.data[i + 2] - b2.data[i + 2]))
    if (d >= 4) over++
  }
  const pct = 100 * over / (a.data.length / 4)
  ok("the sky moves perceptibly within three seconds (>12%)", pct > 12, `${pct.toFixed(1)}%`)

  // The flag must actually ripple.
  const flagAt = async ms => { await freeze(ms); await p.waitForTimeout(60)
    return p.evaluate(() => getComputedStyle(document.querySelector(".flag .pennant")).transform) }
  const f1 = await flagAt(0), f2 = await flagAt(880)
  ok("the flag ripples in the wind", f1 !== f2, `${f1} vs ${f2}`)
  const poleAt = async ms => { await freeze(ms); await p.waitForTimeout(60)
    return p.evaluate(() => getComputedStyle(document.querySelector(".flag .pole")).transform) }
  ok("the flagpole sways", (await poleAt(0)) !== (await poleAt(1400)))

  // A bird crosses the sky.
  const birdAt = async ms => { await freeze(ms); await p.waitForTimeout(60)
    return p.evaluate(() => {
      const b = document.querySelector(".bird-1"), r = b.getBoundingClientRect()
      return { left: Math.round(r.left), opacity: +getComputedStyle(b).opacity }
    }) }
  const b1 = await birdAt(6000), b2p = await birdAt(11000)
  ok("a bird is on screen partway through its cycle",
    b1.left > -40 && b1.left < 900 && b1.opacity > 0.4, JSON.stringify(b1))
  ok("the bird flies across", b2p.left - b1.left > 60, `${b1.left} -> ${b2p.left}`)
  ok("the bird is hidden for part of the cycle", (await birdAt(45000)).opacity < 0.1)
  const wingAt = async ms => { await freeze(ms); await p.waitForTimeout(60)
    return p.evaluate(() => getComputedStyle(document.querySelector(".bird-1 .l")).transform) }
  ok("the bird flaps", (await wingAt(6000)) !== (await wingAt(6210)))
  await p.context().close()
}

// -------------------------------------------------------- 6c. wind
// Wind is a hole property: the flag is the only gauge and sand only appears
// when it is really blowing, so both have to actually respond.
{
  const resumeAt = async (hole) => {
    const p = await newPage()
    await p.evaluate(h => localStorage.setItem("g0lf.run.v1", `1|${h}|20|0|1|1|0`), hole)
    await p.reload({ waitUntil: "networkidle" })
    await p.waitForTimeout(400)
    return p
  }
  const read = p => p.evaluate(() => {
    const st = getComputedStyle(document.getElementById("stage"))
    const pen = getComputedStyle(document.querySelector(".flag .pennant"))
    return {
      wind: parseFloat(st.getPropertyValue("--wind")),
      dir: st.getPropertyValue("--wind-dir").trim(),
      rotate: pen.rotate, scale: pen.scale,
      ripple: parseFloat(pen.animationDuration),
      sand: parseFloat(getComputedStyle(document.querySelector(".sand")).opacity),
    }
  })

  const calm = await resumeAt(1)          // hole 1 has no wind at all
  const c = await read(calm)
  ok("a calm hole reports no wind", c.wind === 0, JSON.stringify(c))
  ok("the flag hangs limp when calm", parseFloat(c.rotate) > 30, c.rotate)
  ok("no sand on a calm hole", c.sand === 0, "opacity=" + c.sand)
  await calm.context().close()

  const windy = await resumeAt(50)        // hole 50 blows at ~96% of max
  const w = await read(windy)
  ok("a windy hole reports strong wind", w.wind > 0.8, JSON.stringify(w))
  ok("the flag streams out flat when windy", parseFloat(w.rotate) < 10, w.rotate)
  ok("the flag ripples faster when windy", w.ripple < c.ripple, `${w.ripple}s vs ${c.ripple}s`)
  ok("sand blows on a windy hole", w.sand > 0.5, "opacity=" + w.sand)
  await windy.context().close()

  // and a headwind must point the flag the other way
  let flipped = null
  for (const h of [10, 20, 24, 30, 33]) {
    const p = await resumeAt(h)
    const r = await read(p)
    if (r.dir === "-1" && r.wind > 0.15) flipped = r
    await p.context().close()
    if (flipped) break
  }
  ok("a headwind flips the flag to point downwind",
    flipped !== null && flipped.scale.startsWith("-1"), JSON.stringify(flipped))
}

// ------------------------------------------------- 7. reduced motion
{
  const p = await newPage({ reducedMotion: "reduce" })
  const n = await p.evaluate(() => document.getAnimations()
    .map(a => a.animationName).filter(x => /drift|twinkle|disc|flag|pole|bird|flap|blow/.test(x)).length)
  ok("prefers-reduced-motion silences the ambient sky", n === 0, "still running: " + n)
  await p.context().close()
}

// ------------------------------------------------- 8. phone layout
{
  const p = await newPage({ viewport: { width: 844, height: 390 } })
  const rows = await p.evaluate(() => new Set([...document.querySelectorAll(".hud > *")]
    .map(e => Math.round(e.getBoundingClientRect().bottom))).size)
  ok("the HUD does not wrap on a landscape phone", rows <= 2, "distinct rows: " + rows)
  ok("the whole hole is visible (world spans the viewport)",
    await p.evaluate(() => {
      const w = document.getElementById("world").getBoundingClientRect()
      return Math.abs(w.width - window.innerWidth) < 2
    }))
  await p.context().close()
}

// ------------------------------------ 8b. rotating re-projects the world
// The installed app came back from a rotation cropped, with dead space around
// it: the world was still projected for the previous orientation. Rotate back
// and forth and check the projection tracks the viewport every time.
{
  const p = await newPage({ viewport: { width: 390, height: 844 } })
  const fits = async label => {
    const r = await p.evaluate(() => {
      const w = document.getElementById("world").getBoundingClientRect()
      const s = document.getElementById("stage").getBoundingClientRect()
      return {
        world: Math.abs(w.width - innerWidth),
        stageW: Math.abs(s.width - innerWidth),
        stageH: Math.abs(s.height - innerHeight),
        floor: Math.abs(w.bottom - innerHeight),
      }
    })
    ok(`the world fills the screen ${label}`,
      r.world < 2 && r.stageW < 2 && r.stageH < 2 && r.floor < 2, JSON.stringify(r))
  }
  await fits("in portrait")
  for (const [w, h, name] of [
    [844, 390, "rotated to landscape"],
    [390, 844, "rotated back to portrait"],
    [844, 390, "rotated to landscape again"],
  ]) {
    await p.setViewportSize({ width: w, height: h })
    await p.waitForTimeout(700)   // past the delayed re-measure
    await fits(name)
  }
  await p.context().close()
}

// ------------------------------------------- 9. the sun sets behind the dunes
// The disc is painted before the ridges, which looks like it should be enough —
// and is not: both ridge layers are translucent, so the sun showed through them
// as a ghost circle lying on the sand. Checked by looking rather than by reading
// the clip back: three frames isolate the horizon and the sun independently, and
// every pixel the sun paints must be above the crest in its own column.
{
  const p = await newPage()
  // Three frames, differing one element at a time. Changing what an element
  // paints nudges Chromium's rasterisation by 4-7/255 along the clip-path
  // edges, so the threshold has to be above that: measured, an unclipped sun
  // leaks 503 pixels at >15 and a clipped one leaks none, which is the margin
  // this check lives in.
  const frame = async mode => {
    await p.evaluate(m => {
      document.querySelectorAll(".stars,.clouds,.bird,.sand").forEach(e => (e.style.display = "none"))
      document.getElementById("world").style.visibility = m === "sky" ? "hidden" : ""
      document.querySelector(".sun").style.background = m === "dunes" ? "none" : ""
      for (const a of document.getAnimations()) { a.pause(); a.currentTime = 0 }
    }, mode)
    await p.waitForTimeout(150)
    return PNG.sync.read(await p.screenshot({ clip: { x: 0, y: 0, width: 900, height: 600 } }))
  }
  const sky = await frame("sky")      // bare gradient: no dunes, no sun
  const dunes = await frame("dunes")  // dunes on the gradient, sun not painted
  const all = await frame("all")      // dunes and sun
  const delta = (a, b, x, y) => {
    const i = (y * 900 + x) * 4
    return Math.max(Math.abs(a.data[i] - b.data[i]), Math.abs(a.data[i + 1] - b.data[i + 1]),
      Math.abs(a.data[i + 2] - b.data[i + 2]))
  }
  let drawn = 0, leaked = 0, worst = 0
  for (let x = 0; x < 900; x++) {
    // Top of the dune silhouette in this column: the first row where the dunes
    // frame departs from the bare sky.
    let crest = 600
    for (let y = 0; y < 600; y++) if (delta(dunes, sky, x, y) > 12) { crest = y; break }
    for (let y = 0; y < 600; y++) {
      if (delta(all, dunes, x, y) <= 15) continue
      if (y > crest + 2) { leaked++; worst = Math.max(worst, y - crest) } else drawn++
    }
  }
  ok("the sun is actually drawn in the sky", drawn > 800, drawn + " px")
  ok("no part of the sun paints below the dune crest",
    leaked === 0, `${leaked} px, reaching ${worst}px below the horizon`)
  await p.context().close()
}

ok("no page or console errors anywhere", errors.length === 0, errors.slice(0, 4).join("\n         "))

await browser.close()
stop()
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) console.log("failed:\n  - " + failures.join("\n  - "))
process.exit(fail ? 1 : 0)
