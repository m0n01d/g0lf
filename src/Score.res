// The persistent run.
//
// Encoding and decoding are pure, so they are testable and so the storage call
// itself stays an effect at the edge (see `Model.cmd`). The format is a
// version-tagged pipe-delimited line rather than JSON: it is six integers, and
// a leading version means a future format change can discard old saves instead
// of misreading them.

type t = {
  hole: int,
  total: int, // strokes across completed holes
  aces: int,
  best: int, // fewest strokes on any one hole; 0 = no hole finished yet
  bestHole: int,
  cheat: bool,
}

let key = "g0lf.run.v1"
let version = 1

let empty = {hole: 1, total: 0, aces: 0, best: 0, bestHole: 0, cheat: false}

/** Holes actually completed. The counter advances only after a hole is sunk. */
let completed = (s: t) => s.hole - 1

let average = (s: t) =>
  completed(s) <= 0 ? None : Some(Int.toFloat(s.total) /. Int.toFloat(completed(s)))

let encode = (s: t) =>
  [version, s.hole, s.total, s.aces, s.best, s.bestHole, s.cheat ? 1 : 0]
  ->Array.map(v => Int.toString(v))
  ->Array.join("|")

let decode = (raw: string) => {
  let parts = raw->String.split("|")->Array.map(p => Int.fromString(p, ~radix=10))
  switch parts {
  | [Some(v), Some(hole), Some(total), Some(aces), Some(best), Some(bestHole), Some(cheat)]
    if v == version && hole >= 1 && total >= 0 && aces >= 0 && best >= 0 =>
    Some({hole, total, aces, best, bestHole, cheat: cheat == 1})
  | _ => None
  }
}

/** Fold a finished hole into the run. */
let record = (s: t, ~strokes) => {
  hole: s.hole + 1,
  total: s.total + strokes,
  aces: strokes == 1 ? s.aces + 1 : s.aces,
  best: s.best == 0 || strokes < s.best ? strokes : s.best,
  bestHole: s.best == 0 || strokes < s.best ? s.hole : s.bestHole,
  cheat: s.cheat,
}
