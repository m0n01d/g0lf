// Deterministic PRNG (mulberry32). Hole N always generates the same course,
// which is what makes an "infinite" course reproducible and shareable.

type t = {mutable s: int}

@val external imul: (int, int) => int = "Math.imul"

let make = (seed: int) => {s: imul(seed + 0x2f6b, 0x9e3779b1)}

let float = (r: t) => {
  open Int
  r.s = r.s + 0x6d2b79f5
  let a = imul(r.s->bitwiseXor(r.s->shiftRightUnsigned(15)), 1->bitwiseOr(r.s))
  let b = (a + imul(a->bitwiseXor(a->shiftRightUnsigned(7)), 61->bitwiseOr(a)))->bitwiseXor(a)
  let u = b->bitwiseXor(b->shiftRightUnsigned(14))->bitwiseAnd(0x3fffffff)
  Int.toFloat(u) /. 1073741824.0
}

let range = (r: t, lo: float, hi: float) => lo +. (hi -. lo) *. float(r)
