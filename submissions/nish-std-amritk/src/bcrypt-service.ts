// bcrypt off the HTTP workers' event loops: one process that every worker
// reaches over loopback TCP, which batches up to four hashes or four
// verifications into one `bcryptHashN` or `bcryptVerifyN` call of `width` lanes,
// the width `bcryptCalibrate` found fastest on this CPU (BCRYPT_WIDTH in main.ts):
// on the VM's Xeon five lanes take about 1.9 times one hash's time.
// A 64 ms batch inside an HTTP worker would hold every connection that worker
// serves for 64 ms; here it holds only the logins.
//
// The protocol is framed bytes, both ways:
//
//   request  op (1 hash, 2 verify) · id (u32, big-endian) · password length
//            (u8, at most 72) · the password · hash length (u8) · the hash
//   reply    id (u32) · status (1 done or matched, 2 no match, 0 failed) ·
//            hash length (u8) · the hash (a new one, for op 1)
//
// A batch runs once `width` jobs wait, or once the oldest has waited the
// collection window, `windowMs` (BCRYPT_BATCH_MS). Logins and sign-ups share
// it: a sign-up's new hash takes a free lane of a login batch, the login
// checked by hashing its password with its stored hash's salt, so a sign-up
// costs one lane more instead of a one-lane call of its own. Every password is
// copied into a fresh array the batch wraps as a `Secret`, and that array
// and the frame it came in are wiped once the batch has run. Every login
// verifies against its stored hash, and every hash is cost 10 with a salt
// from the CSPRNG: nothing is remembered between jobs (the challenge's rules
// 5 and 7).
import {
  netClose,
  netRead,
  netWrite,
  pollAdd,
  pollCreate,
  pollModify,
  pollRemove,
  pollWait,
  tcpAccept,
} from "nish:net"
import { monotonicNanos } from "nish:process"
import { Secret, secret, wipe } from "nish:secret"
import { bcryptHashN, bcryptVerifyN } from "nish/crypto/bcrypt"

export const BCRYPT_OP_HASH: i32 = 1
export const BCRYPT_OP_VERIFY: i32 = 2
export const BCRYPT_DONE: i32 = 1
export const BCRYPT_MISMATCH: i32 = 2
export const BCRYPT_FAILED: i32 = 0
/** The cost every hash is made with: SPEC.md's. */
const BCRYPT_COST: i32 = 10
/** The most jobs one call takes: `bcryptHashN`'s and `bcryptVerifyN`'s lanes. */
export const BCRYPT_LANES: i32 = 6
/**
 * The longest password a frame carries: bcrypt reads no more. SPEC.md sets no
 * limit; the server refuses a longer one (422 at sign-up and update, 401 at
 * login) rather than hash a prefix of it.
 */
export const BCRYPT_MAX_PASSWORD: i32 = 72
/** The longest hash a frame carries. */
const BCRYPT_MAX_HASH: i32 = 64
/** The most jobs of one kind that wait; past it a job is answered failed at once. */
const BCRYPT_QUEUE: i32 = 4096
/** The most workers connected at once. */
const BCRYPT_CLIENTS: i32 = 64
const BCRYPT_LISTENER: i32 = -1
const BCRYPT_AGAIN: i32 = -11
const BCRYPT_IN: i32 = 8192
const BCRYPT_OUT: i32 = 65536

/** One worker's connection to the service. */
class BcryptPeer {
  fd: i32 = -1
  input: u8[]
  inputEnd: i32 = 0
  output: u8[]
  outputStart: i32 = 0
  outputEnd: i32 = 0

  constructor() {
    this.input = new Array<u8>(BCRYPT_IN)
    this.output = new Array<u8>(BCRYPT_OUT)
  }
}

/** The jobs of one kind, oldest first, in a ring. */
class BcryptQueue {
  peer: i32[]
  id: i32[]
  password: u8[][]
  passwordLength: i32[]
  hash: u8[][]
  hashLength: i32[]
  since: i64[]
  head: i32 = 0
  count: i32 = 0

  constructor() {
    this.peer = new Array<i32>(BCRYPT_QUEUE)
    this.id = new Array<i32>(BCRYPT_QUEUE)
    this.password = []
    this.passwordLength = new Array<i32>(BCRYPT_QUEUE)
    this.hash = []
    this.hashLength = new Array<i32>(BCRYPT_QUEUE)
    this.since = new Array<i64>(BCRYPT_QUEUE)
    for (let k: i32 = 0; k < BCRYPT_QUEUE; k++) {
      this.password.push(new Array<u8>(BCRYPT_MAX_PASSWORD))
      this.hash.push(new Array<u8>(BCRYPT_MAX_HASH))
    }
  }

  /** The ring index of the `k`th oldest job. */
  at(k: i32): i32 {
    return (this.head + k) % BCRYPT_QUEUE
  }
}

/** A fresh array holding `src[0, len)`, for a batch to wrap as a `Secret`. */
const bcryptCopy = (src: u8[], len: i32): u8[] => {
  const out: u8[] = new Array<u8>(len)
  for (let k: i32 = 0; k < len && k < toI32(src.length); k++) {
    out[k] = src[k]
  }
  return out
}

/** Lane `k` of a batch of `n`: its password as a `Secret`, or null past `n`. */
const bcryptLane = (q: BcryptQueue, n: i32, k: i32): Secret<u8[]> | null => {
  if (k >= n) {
    return null
  }
  const at: i32 = q.at(k)
  return secret(bcryptCopy(q.password[at], q.passwordLength[at]))
}

/** A check's answer: the password matched, or it did not. */
const bcryptOutcome = (matched: boolean): i32 => (matched ? BCRYPT_DONE : BCRYPT_MISMATCH)

/** Queues the reply to job `at` of `q` on its peer: `status`, and `hash` when given. */
const bcryptReply = (peers: BcryptPeer[], q: BcryptQueue, at: i32, status: i32, hash: string): void => {
  bcryptReplyTo(peers, q.peer[at], q.id[at], status, hash)
}

/** Queues the reply to job `id` on peer `p`. */
const bcryptReplyTo = (peers: BcryptPeer[], p: i32, id: i32, status: i32, hash: string): void => {
  if (p < 0 || p >= toI32(peers.length)) {
    return
  }
  const peer: BcryptPeer = peers[p]
  const len: i32 = toI32(hash.length)
  if (peer.fd < 0 || peer.outputEnd + 6 + len > toI32(peer.output.length)) {
    return
  }
  const o: u8[] = peer.output
  let e: i32 = peer.outputEnd
  o[e] = toU8((id >> 24) & 255)
  o[e + 1] = toU8((id >> 16) & 255)
  o[e + 2] = toU8((id >> 8) & 255)
  o[e + 3] = toU8(id & 255)
  o[e + 4] = toU8(status)
  o[e + 5] = toU8(len)
  e += 6
  for (let k: i32 = 0; k < len; k++) {
    o[e + k] = toU8(hash.charCodeAt(k))
  }
  peer.outputEnd = e + len
}

/** Wipes the passwords of the oldest `n` jobs of `q` and drops them. */
const bcryptRetire = (q: BcryptQueue, n: i32): void => {
  for (let k: i32 = 0; k < n; k++) {
    wipe(q.password[q.at(k)])
  }
  q.head = q.at(n)
  q.count -= n
}

/** Hashes the oldest `n` (1 to 6) jobs of `q` in one call and replies to each. */
const bcryptRunHash = (peers: BcryptPeer[], q: BcryptQueue, n: i32): void => {
  const p0: Secret<u8[]> = secret(bcryptCopy(q.password[q.head], q.passwordLength[q.head]))
  const p1: Secret<u8[]> | null = bcryptLane(q, n, 1)
  const p2: Secret<u8[]> | null = bcryptLane(q, n, 2)
  const p3: Secret<u8[]> | null = bcryptLane(q, n, 3)
  const p4: Secret<u8[]> | null = bcryptLane(q, n, 4)
  const p5: Secret<u8[]> | null = bcryptLane(q, n, 5)
  const salts: u8[] = new Array<u8>(96)
  crypto.getRandomValues(salts)
  const made: Result<string[], string> = bcryptHashN(p0, p1, p2, p3, p4, p5, salts, BCRYPT_COST)
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
  for (let k: i32 = 0; k < n; k++) {
    if (made.isErr()) {
      bcryptReply(peers, q, q.at(k), BCRYPT_FAILED, "")
    } else {
      bcryptReply(peers, q, q.at(k), BCRYPT_DONE, made.value[k])
    }
  }
  bcryptRetire(q, n)
}

/** Verifies the oldest `n` (1 to 6) jobs of `q` against their hashes in one call and replies to each. */
const bcryptRunVerify = (peers: BcryptPeer[], q: BcryptQueue, n: i32): void => {
  const hashes: string[] = []
  for (let k: i32 = 0; k < BCRYPT_LANES; k++) {
    // An empty lane repeats lane 0's hash, which bcryptVerifyN does not read.
    const at: i32 = q.at(k < n ? k : 0)
    hashes.push(String.fromBytes(q.hash[at], 0, q.hashLength[at]))
  }
  const p0: Secret<u8[]> = secret(bcryptCopy(q.password[q.head], q.passwordLength[q.head]))
  const p1: Secret<u8[]> | null = bcryptLane(q, n, 1)
  const p2: Secret<u8[]> | null = bcryptLane(q, n, 2)
  const p3: Secret<u8[]> | null = bcryptLane(q, n, 3)
  const p4: Secret<u8[]> | null = bcryptLane(q, n, 4)
  const p5: Secret<u8[]> | null = bcryptLane(q, n, 5)
  const checked: Result<boolean[], string> = bcryptVerifyN(p0, p1, p2, p3, p4, p5, hashes)
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
  if (checked.isErr() && n > 1) {
    // One malformed stored hash fails the whole call: verify each alone, so
    // only its own login fails.
    for (let k: i32 = 0; k < n; k++) {
      bcryptRunVerifyOne(peers, q, q.at(k))
    }
  } else {
    for (let k: i32 = 0; k < n; k++) {
      const status: i32 = checked.isErr() ? BCRYPT_FAILED : bcryptOutcome(checked.value[k])
      bcryptReply(peers, q, q.at(k), status, "")
    }
  }
  bcryptRetire(q, n)
}

/** The sextet bcrypt's base64 (`./A-Za-z0-9`) gives character `c`, or -1. */
const bcryptSextet = (c: i32): i32 => {
  if (c === 46 || c === 47) {
    return c - 46
  }
  if (c >= 65 && c <= 90) {
    return c - 63
  }
  if (c >= 97 && c <= 122) {
    return c - 69
  }
  if (c >= 48 && c <= 57) {
    return c + 6
  }
  return -1
}

/**
 * Whether job `at` of `q`, a login, can be checked by hashing its password
 * with its stored hash's salt in a `bcryptHashN` call: a 60-character
 * `$2b$10$` or `$2y$10$` hash, or a `$2a$10$` one with an ASCII password
 * (`$2a$` differs from `$2b$` only for bytes above 0x7f), with a salt in
 * bcrypt's alphabet. Its salt's 16 bytes go to `salts[16 * lane]`.
 */
const bcryptRideSalt = (q: BcryptQueue, at: i32, salts: u8[], lane: i32): boolean => {
  const h: u8[] = q.hash[at]
  if (q.hashLength[at] !== 60 || toI32(h.length) < 60) {
    return false
  }
  const minor: i32 = toI32(h[2])
  if (toI32(h[0]) !== 36 || toI32(h[1]) !== 50 || toI32(h[3]) !== 36 || toI32(h[4]) !== 49 || toI32(h[5]) !== 48 || toI32(h[6]) !== 36) {
    return false
  }
  if (minor === 97) {
    const pw: u8[] = q.password[at]
    for (let k: i32 = 0; k < q.passwordLength[at] && k < toI32(pw.length); k++) {
      if (toI32(pw[k]) > 127) {
        return false
      }
    }
  } else if (minor !== 98 && minor !== 121) {
    return false
  }
  // BF_decode of the 22 salt characters: 16 bytes, the last character's top two bits.
  const sx: i32[] = new Array<i32>(22)
  for (let k: i32 = 0; k < 22; k++) {
    sx[k] = bcryptSextet(toI32(h[7 + k]))
    if (sx[k] < 0) {
      return false
    }
  }
  const o: i32 = 16 * lane
  let src: i32 = 0
  let d: i32 = 0
  while (d + 2 < 15) {
    salts[o + d] = toU8((sx[src] << 2) | ((sx[src + 1] & 0x30) >> 4))
    salts[o + d + 1] = toU8(((sx[src + 1] & 0x0f) << 4) | ((sx[src + 2] & 0x3c) >> 2))
    salts[o + d + 2] = toU8(((sx[src + 2] & 0x03) << 6) | sx[src + 3])
    src += 4
    d += 3
  }
  salts[o + 15] = toU8((sx[20] << 2) | ((sx[21] & 0x30) >> 4))
  return true
}

/** Whether `made`'s digest (its last 31 characters) is job `at`'s stored one, compared in constant time. */
const bcryptSameDigest = (made: string, q: BcryptQueue, at: i32): boolean => {
  const h: u8[] = q.hash[at]
  if (toI32(made.length) !== 60) {
    return false
  }
  let diff: i32 = 0
  for (let k: i32 = 29; k < 60; k++) {
    diff = diff | (toI32(made.charCodeAt(k)) ^ toI32(h[k]))
  }
  return diff === 0
}

/** Job `at` of `q`'s password as a fresh `Secret`, or null for a lane past the batch. */
const bcryptSecretAt = (q: BcryptQueue, at: i32, used: boolean): Secret<u8[]> | null =>
  used ? secret(bcryptCopy(q.password[at], q.passwordLength[at])) : null

/**
 * The oldest `nv` logins of `verifies` and the oldest `nh` sign-ups of
 * `hashes` in one `bcryptHashN` call of `nv + nh` lanes (1 to 6): each login
 * is hashed with its stored hash's salt and matches when the digest is the
 * stored one, which is what `bcryptVerify` checks; each sign-up gets a fresh
 * salt. A sign-up costs a login batch one more lane (about 7 ms at cost 10)
 * instead of a call of its own (about 58 ms). False, with nothing run, when
 * a login cannot be checked that way (`bcryptRideSalt`).
 */
const bcryptRunMixed = (peers: BcryptPeer[], verifies: BcryptQueue, nv: i32, hashes: BcryptQueue, nh: i32): boolean => {
  const salts: u8[] = new Array<u8>(96)
  crypto.getRandomValues(salts)
  for (let k: i32 = 0; k < nv; k++) {
    if (!bcryptRideSalt(verifies, verifies.at(k), salts, k)) {
      return false
    }
  }
  const n: i32 = nv + nh
  const ats: i32[] = new Array<i32>(BCRYPT_LANES)
  for (let k: i32 = 0; k < BCRYPT_LANES; k++) {
    ats[k] = k < nv ? verifies.at(k) : k < n ? hashes.at(k - nv) : 0
  }
  const p0: Secret<u8[]> = secret(
    nv > 0 ? bcryptCopy(verifies.password[ats[0]], verifies.passwordLength[ats[0]]) : bcryptCopy(hashes.password[ats[0]], hashes.passwordLength[ats[0]])
  )
  const p1: Secret<u8[]> | null = bcryptSecretAt(1 < nv ? verifies : hashes, ats[1], 1 < n)
  const p2: Secret<u8[]> | null = bcryptSecretAt(2 < nv ? verifies : hashes, ats[2], 2 < n)
  const p3: Secret<u8[]> | null = bcryptSecretAt(3 < nv ? verifies : hashes, ats[3], 3 < n)
  const p4: Secret<u8[]> | null = bcryptSecretAt(4 < nv ? verifies : hashes, ats[4], 4 < n)
  const p5: Secret<u8[]> | null = bcryptSecretAt(5 < nv ? verifies : hashes, ats[5], 5 < n)
  const made: Result<string[], string> = bcryptHashN(p0, p1, p2, p3, p4, p5, salts, BCRYPT_COST)
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
  wipe(salts)
  if (made.isErr()) {
    return false
  }
  for (let k: i32 = 0; k < nv; k++) {
    bcryptReply(peers, verifies, ats[k], bcryptOutcome(bcryptSameDigest(made.value[k], verifies, ats[k])), "")
  }
  for (let k: i32 = nv; k < n; k++) {
    bcryptReply(peers, hashes, ats[k], BCRYPT_DONE, made.value[k])
  }
  bcryptRetire(verifies, nv)
  bcryptRetire(hashes, nh)
  return true
}

/** Verifies job `at` of `q` alone. */
const bcryptRunVerifyOne = (peers: BcryptPeer[], q: BcryptQueue, at: i32): void => {
  const hashes: string[] = []
  for (let k: i32 = 0; k < BCRYPT_LANES; k++) {
    hashes.push(String.fromBytes(q.hash[at], 0, q.hashLength[at]))
  }
  const p0: Secret<u8[]> = secret(bcryptCopy(q.password[at], q.passwordLength[at]))
  const checked: Result<boolean[], string> = bcryptVerifyN(p0, null, null, null, null, null, hashes)
  wipe(p0)
  const status: i32 = checked.isErr() ? BCRYPT_FAILED : bcryptOutcome(checked.value[0])
  bcryptReply(peers, q, at, status, "")
}

/**
 * Takes the whole frames in `peer`'s input onto the queues, wipes them and
 * keeps what is left of a partial one; false when a frame is malformed.
 */
const bcryptTake = (
  peers: BcryptPeer[],
  p: i32,
  hashes: BcryptQueue,
  verifies: BcryptQueue,
  now: i64
): boolean => {
  const peer: BcryptPeer = peers[p]
  const b: u8[] = peer.input
  let at: i32 = 0
  while (true) {
    if (peer.inputEnd - at < 7) {
      break
    }
    const op: i32 = toI32(b[at])
    const pwLen: i32 = toI32(b[at + 5])
    if ((op !== BCRYPT_OP_HASH && op !== BCRYPT_OP_VERIFY) || pwLen > BCRYPT_MAX_PASSWORD) {
      return false
    }
    if (peer.inputEnd - at < 7 + pwLen) {
      break
    }
    const hashLen: i32 = toI32(b[at + 6 + pwLen])
    if (hashLen > BCRYPT_MAX_HASH) {
      return false
    }
    const size: i32 = 7 + pwLen + hashLen
    if (peer.inputEnd - at < size) {
      break
    }
    const q: BcryptQueue = op === BCRYPT_OP_HASH ? hashes : verifies
    const id: i32 =
      (toI32(b[at + 1]) << 24) | (toI32(b[at + 2]) << 16) | (toI32(b[at + 3]) << 8) | toI32(b[at + 4])
    if (q.count === BCRYPT_QUEUE) {
      bcryptReplyTo(peers, p, id, BCRYPT_FAILED, "")
    } else {
      const slot: i32 = q.at(q.count)
      q.peer[slot] = p
      q.id[slot] = id
      q.passwordLength[slot] = pwLen
      q.hashLength[slot] = hashLen
      q.since[slot] = now
      const pw: u8[] = q.password[slot]
      for (let k: i32 = 0; k < pwLen; k++) {
        pw[k] = b[at + 6 + k]
      }
      const hash: u8[] = q.hash[slot]
      for (let k: i32 = 0; k < hashLen; k++) {
        hash[k] = b[at + 7 + pwLen + k]
      }
      q.count += 1
    }
    at += size
  }
  // The consumed frames held passwords: wipe them as the rest moves down.
  const left: i32 = peer.inputEnd - at
  for (let k: i32 = 0; k < left; k++) {
    b[k] = b[at + k]
  }
  for (let k: i32 = left; k < peer.inputEnd; k++) {
    b[k] = toU8(0)
  }
  peer.inputEnd = left
  return true
}

/** Sends what `peer` holds until the socket would block; false when it is gone. */
const bcryptSend = (peer: BcryptPeer): boolean => {
  while (peer.outputEnd > peer.outputStart) {
    const n: i32 = netWrite(peer.fd, peer.output, peer.outputStart, peer.outputEnd - peer.outputStart)
    if (n === BCRYPT_AGAIN) {
      return true
    }
    if (n <= 0) {
      return false
    }
    peer.outputStart += n
  }
  peer.outputStart = 0
  peer.outputEnd = 0
  return true
}

/** Drops jobs whose peer is `p`, which has gone, by pointing them nowhere. */
const bcryptForget = (q: BcryptQueue, p: i32): void => {
  for (let k: i32 = 0; k < q.count; k++) {
    const at: i32 = q.at(k)
    if (q.peer[at] === p) {
      q.peer[at] = -1
    }
  }
}

/**
 * How many jobs a batch of logins and sign-ups together takes now, logins
 * first: up to `width` once that many wait, all of them once the oldest of
 * either has waited `windowNs`, and none before.
 */
const bcryptDueMixed = (verifies: BcryptQueue, hashes: BcryptQueue, now: i64, windowNs: i64, width: i32): i32 => {
  const n: i32 = verifies.count + hashes.count
  if (n === 0) {
    return 0
  }
  if (n >= width) {
    return width
  }
  const oldest: boolean =
    (verifies.count > 0 && now - verifies.since[verifies.head] >= windowNs) ||
    (hashes.count > 0 && now - hashes.since[hashes.head] >= windowNs)
  return oldest ? n : 0
}

/** Serves the workers on `listener` until the process is stopped. Answers only on a failure to poll. */
export const runBcryptService = (listener: i32, windowMs: i32, width: i32): i32 => {
  const loop: i32 = pollCreate()
  if (loop < 0 || pollAdd(loop, listener, 1, BCRYPT_LISTENER) < 0) {
    return 1
  }
  const peers: BcryptPeer[] = []
  for (let k: i32 = 0; k < BCRYPT_CLIENTS; k++) {
    peers.push(new BcryptPeer())
  }
  const hashes: BcryptQueue = new BcryptQueue()
  const verifies: BcryptQueue = new BcryptQueue()
  const ready: i32[] = new Array<i32>(2 * BCRYPT_CLIENTS + 2)
  const address: u8[] = new Array<u8>(18)
  const windowNs: i64 = toI64(windowMs) * 1000000
  while (true) {
    // Wait no longer than the oldest job's window has left.
    let wait: i32 = -1
    const now0: i64 = monotonicNanos()
    for (const q of [hashes, verifies]) {
      if (q.count > 0) {
        const left: i64 = q.since[q.head] + windowNs - now0
        const ms: i32 = left <= 0 ? 0 : toI32(left / 1000000) + 1
        if (wait < 0 || ms < wait) {
          wait = ms
        }
      }
    }
    const n: i32 = pollWait(loop, ready, wait)
    if (n < 0 && n !== -4) {
      return 1
    }
    const now: i64 = monotonicNanos()
    for (let k: i32 = 0; k < n; k++) {
      const token: i32 = ready[2 * k]
      if (token === BCRYPT_LISTENER) {
        let fd: i32 = tcpAccept(listener, address)
        while (fd >= 0) {
          let p: i32 = -1
          for (let j: i32 = 0; j < BCRYPT_CLIENTS && p < 0; j++) {
            if (peers[j].fd < 0) {
              p = j
            }
          }
          if (p < 0 || pollAdd(loop, fd, 1, p) < 0) {
            netClose(fd)
          } else {
            const peer: BcryptPeer = peers[p]
            peer.fd = fd
            peer.inputEnd = 0
            peer.outputStart = 0
            peer.outputEnd = 0
          }
          fd = tcpAccept(listener, address)
        }
      } else if (token >= 0 && token < BCRYPT_CLIENTS) {
        const peer: BcryptPeer = peers[token]
        if (peer.fd >= 0) {
          let alive: boolean = true
          if ((ready[2 * k + 1] & 5) !== 0) {
            const got: i32 = netRead(
              peer.fd,
              peer.input,
              peer.inputEnd,
              toI32(peer.input.length) - peer.inputEnd
            )
            if (got === 0 || (got < 0 && got !== BCRYPT_AGAIN)) {
              alive = false
            } else if (got > 0) {
              peer.inputEnd += got
              alive = bcryptTake(peers, token, hashes, verifies, now)
            }
          }
          alive = alive && bcryptSend(peer)
          if (!alive) {
            pollRemove(loop, peer.fd)
            netClose(peer.fd)
            peer.fd = -1
            wipe(peer.input)
            peer.inputEnd = 0
            bcryptForget(hashes, token)
            bcryptForget(verifies, token)
          } else {
            pollModify(loop, peer.fd, peer.outputEnd > peer.outputStart ? 3 : 1, token)
          }
        }
      }
    }
    // Run every batch that is due, then send the replies. A login batch
    // takes the sign-ups waiting into its free lanes; a sign-up waits as long
    // as a login does for that, and runs alone (in batches of its own) only
    // when no login batch came due in time.
    let due: i32 = bcryptDueMixed(verifies, hashes, monotonicNanos(), windowNs, width)
    while (due > 0) {
      const nv: i32 = due < verifies.count ? due : verifies.count
      const nh: i32 = due - nv
      if (nv === 0 || !bcryptRunMixed(peers, verifies, nv, hashes, nh)) {
        if (nv > 0) {
          bcryptRunVerify(peers, verifies, nv)
        }
        if (nh > 0) {
          bcryptRunHash(peers, hashes, nh)
        }
      }
      due = bcryptDueMixed(verifies, hashes, monotonicNanos(), windowNs, width)
    }
    for (let p: i32 = 0; p < BCRYPT_CLIENTS; p++) {
      const peer: BcryptPeer = peers[p]
      if (peer.fd >= 0 && peer.outputEnd > peer.outputStart) {
        if (bcryptSend(peer)) {
          pollModify(loop, peer.fd, peer.outputEnd > peer.outputStart ? 3 : 1, p)
        }
      }
    }
  }
}

/**
 * A worker's end of the service: requests queued with `hash` and `verify`,
 * sent by the worker's loop, and replies read with `nextReply` after
 * `received`. The worker owns the socket and its readiness.
 */
export class BcryptClient {
  fd: i32 = -1
  connected: boolean = false
  output: u8[]
  outputStart: i32 = 0
  outputEnd: i32 = 0
  input: u8[]
  inputStart: i32 = 0
  inputEnd: i32 = 0
  /** The reply `nextReply` read: its id, status and hash bytes. */
  replyId: i32 = 0
  replyStatus: i32 = 0
  replyHash: u8[]
  replyHashLength: i32 = 0
  /** The service's address; when a connect last failed (0 while none has) and when to try again. */
  address: u8[]
  failedAt: i64 = 0
  retryAt: i64 = 0
  /** Jobs sent and not yet answered. */
  inFlight: i32 = 0
  /** Unreachable past the worker's patience: given no jobs while another service is up. */
  down: boolean = false

  constructor() {
    this.address = new Array<u8>(18)
    this.output = new Array<u8>(BCRYPT_OUT)
    this.input = new Array<u8>(BCRYPT_IN)
    this.replyHash = new Array<u8>(BCRYPT_MAX_HASH)
  }

  /** Queues a request; false when the output is full. */
  request(op: i32, id: i32, pw: u8[], pwLen: i32, hash: u8[], hashOff: i32, hashLen: i32): boolean {
    if (pwLen < 0 || pwLen > BCRYPT_MAX_PASSWORD || hashLen < 0 || hashLen > BCRYPT_MAX_HASH) {
      return false
    }
    if (this.outputStart === this.outputEnd) {
      this.outputStart = 0
      this.outputEnd = 0
    }
    const size: i32 = 7 + pwLen + hashLen
    if (this.outputEnd + size > toI32(this.output.length)) {
      return false
    }
    const o: u8[] = this.output
    const e: i32 = this.outputEnd
    o[e] = toU8(op)
    o[e + 1] = toU8((id >> 24) & 255)
    o[e + 2] = toU8((id >> 16) & 255)
    o[e + 3] = toU8((id >> 8) & 255)
    o[e + 4] = toU8(id & 255)
    o[e + 5] = toU8(pwLen)
    for (let k: i32 = 0; k < pwLen; k++) {
      o[e + 6 + k] = pw[k]
    }
    o[e + 6 + pwLen] = toU8(hashLen)
    for (let k: i32 = 0; k < hashLen; k++) {
      o[e + 7 + pwLen + k] = hash[hashOff + k]
    }
    this.outputEnd = e + size
    return true
  }

  /** Sends what is queued until the socket would block, wiping what went; false when the socket is gone. */
  send(): boolean {
    while (this.outputEnd > this.outputStart) {
      const n: i32 = netWrite(this.fd, this.output, this.outputStart, this.outputEnd - this.outputStart)
      if (n === BCRYPT_AGAIN) {
        return true
      }
      if (n <= 0) {
        return false
      }
      for (let k: i32 = this.outputStart; k < this.outputStart + n; k++) {
        this.output[k] = toU8(0)
      }
      this.outputStart += n
    }
    this.outputStart = 0
    this.outputEnd = 0
    return true
  }

  /** Reads what the socket holds; false when it is gone. */
  receive(): boolean {
    if (this.inputStart > 0) {
      const left: i32 = this.inputEnd - this.inputStart
      for (let k: i32 = 0; k < left; k++) {
        this.input[k] = this.input[this.inputStart + k]
      }
      this.inputStart = 0
      this.inputEnd = left
    }
    const got: i32 = netRead(this.fd, this.input, this.inputEnd, toI32(this.input.length) - this.inputEnd)
    if (got === BCRYPT_AGAIN) {
      return true
    }
    if (got <= 0) {
      return false
    }
    this.inputEnd += got
    return true
  }

  /** Reads the next whole reply into `replyId`, `replyStatus` and `replyHash`; false when none is whole yet. */
  nextReply(): boolean {
    const b: u8[] = this.input
    const at: i32 = this.inputStart
    if (this.inputEnd - at < 6) {
      return false
    }
    const len: i32 = toI32(b[at + 5])
    if (this.inputEnd - at < 6 + len || len > BCRYPT_MAX_HASH) {
      return false
    }
    this.replyId =
      (toI32(b[at]) << 24) | (toI32(b[at + 1]) << 16) | (toI32(b[at + 2]) << 8) | toI32(b[at + 3])
    this.replyStatus = toI32(b[at + 4])
    for (let k: i32 = 0; k < len; k++) {
      this.replyHash[k] = b[at + 6 + k]
    }
    this.replyHashLength = len
    this.inputStart = at + 6 + len
    return true
  }

  /** Forgets the connection and wipes what was queued for it. */
  reset(): void {
    wipe(this.output)
    this.fd = -1
    this.connected = false
    this.inFlight = 0
    this.outputStart = 0
    this.outputEnd = 0
    this.inputStart = 0
    this.inputEnd = 0
  }
}
