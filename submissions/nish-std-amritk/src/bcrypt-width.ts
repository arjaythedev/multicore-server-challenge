// Picks the bcrypt batch width for the machine it runs on, once, at build
// time: build.sh runs it and start.sh hands its answer to the server as
// BCRYPT_WIDTH. The fastest width per hash turns on the core (on a Xeon
// Platinum 8260 five lanes beat six, on a Ryzen 9 9950X six beat five, by 2
// to 5%), and `bcryptCalibrate`, timed at startup, is too short to tell them
// apart: each process raced the others and chose three or five lanes from one
// start to the next. Here one process on a quiet box times widths 3 to 6,
// interleaved round by round, at cost 8, and takes each width's median.
//
// It prints the width, 3 to 6, and nothing else.
import { bcryptHashN } from "nish/crypto/bcrypt"
import { monotonicNanos } from "nish:process"
import { Secret, secret, wipe } from "nish:secret"

const ROUNDS: i32 = 9
const COST: i32 = 8
const LOW: i32 = 3
const HIGH: i32 = 6

const password = (k: i32): Secret<u8[]> => {
  const b: u8[] = new Array<u8>(12)
  for (let j: i32 = 0; j < 12; j++) {
    b[j] = toU8(97 + ((k * 7 + j) % 26))
  }
  return secret(b)
}

const lane = (w: i32, k: i32): Secret<u8[]> | null => (k < w ? password(k) : null)

/** One batch of `w` lanes at `COST`: ns per hash, or -1 when it failed. */
const timeWidth = (w: i32, salts: u8[]): i64 => {
  const p0: Secret<u8[]> = password(0)
  const p1: Secret<u8[]> | null = lane(w, 1)
  const p2: Secret<u8[]> | null = lane(w, 2)
  const p3: Secret<u8[]> | null = lane(w, 3)
  const p4: Secret<u8[]> | null = lane(w, 4)
  const p5: Secret<u8[]> | null = lane(w, 5)
  const t0: i64 = monotonicNanos()
  const made: Result<string[], string> = bcryptHashN(p0, p1, p2, p3, p4, p5, salts, COST)
  const t1: i64 = monotonicNanos()
  wipe(p0)
  if (p1 !== null) {
    wipe(p1)
  }
  if (p2 !== null) {
    wipe(p2)
  }
  if (p3 !== null) {
    wipe(p3)
  }
  if (p4 !== null) {
    wipe(p4)
  }
  if (p5 !== null) {
    wipe(p5)
  }
  return made.isOk() ? (t1 - t0) / toI64(w) : toI64(-1)
}

export const main = (): i32 => {
  const salts: u8[] = new Array<u8>(96)
  crypto.getRandomValues(salts)
  const n: i32 = HIGH - LOW + 1
  const times: i64[] = new Array<i64>(n * ROUNDS)
  // A warm-up batch of each, then the rounds, each width once a round.
  for (let w: i32 = LOW; w <= HIGH; w++) {
    timeWidth(w, salts)
  }
  for (let r: i32 = 0; r < ROUNDS; r++) {
    for (let w: i32 = LOW; w <= HIGH; w++) {
      times[(w - LOW) * ROUNDS + r] = timeWidth(w, salts)
    }
  }
  let best: i32 = HIGH
  let bestTime: i64 = toI64(-1)
  for (let w: i32 = LOW; w <= HIGH; w++) {
    // The median of the width's rounds: insertion sort of nine.
    const s: i64[] = new Array<i64>(ROUNDS)
    for (let r: i32 = 0; r < ROUNDS; r++) {
      const v: i64 = times[(w - LOW) * ROUNDS + r]
      let j: i32 = r
      while (j > 0 && s[j - 1] > v) {
        s[j] = s[j - 1]
        j--
      }
      s[j] = v
    }
    const median: i64 = s[ROUNDS / 2]
    if (s[0] >= toI64(0) && (bestTime < toI64(0) || median < bestTime)) {
      best = w
      bestTime = median
    }
  }
  console.log(`${best}`)
  return 0
}
