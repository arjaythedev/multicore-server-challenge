// The rings between the HTTP workers and the read service: one region the
// supervisor makes before it starts them, and in it, per HTTP worker, a ring
// of reads to the service and a ring of answers back. A busy ring is memory
// and no system call; a side with nothing to do sleeps in its loop, on the
// worker's prefork service channel, and says so in a flag here, so a push
// writes that channel only when the other side would otherwise not look.
//
// A read is [tag i32][kind i32][key length i32][4 unused][viewer i64]
// [limit i64][offset i64][key]. An answer is its body, then [tag i32]
// [status i32] after the body, so the worker writes the body from the start
// of its buffer as it would any other. A tag is the request's index in its
// worker, and the request stays in the worker's hands (`inPool`) until its
// answer comes: a closed connection's request is freed then, so a tag names
// nothing else meanwhile.
import { netRead, netWrite } from "nish:net"
import {
  attachSpscRing,
  initSpscRing,
  SpscRing,
  spscRingBytes,
} from "nish/sync/ring"
import { fence, RELAXED, SEQ_CST, SharedRegion } from "nish/sync/shm"

/** The bytes of a read before its key. */
export const READ_HEAD: i32 = 40
/** The bytes after an answer's body. */
export const ANSWER_TAIL: i32 = 8
/** A status no HTTP answer has: the worker sends the request alone. Positive: `setI32LE` writes a negative as 0. */
export const ANSWER_ALONE: i32 = 1

const READ_RING: i32 = 1048576
const ANSWER_RING: i32 = 16777216
/** The longest answer the rings carry; a longer one is read alone by its worker. */
export const ANSWER_MAX: i32 = 1048576
/** The service's sleep flag, then one a worker, each with a cache line. */
const FLAGS_BYTES: i32 = 4096
const SERVICE_FLAG: i32 = 0
const workerFlag = (w: i32): i32 => 64 * (w + 1)
const readRingAt = (w: i32): i32 =>
  FLAGS_BYTES + w * (spscRingBytes(READ_RING) + spscRingBytes(ANSWER_RING))
const answerRingAt = (w: i32): i32 => readRingAt(w) + spscRingBytes(READ_RING)

/** The region's size for `workers` HTTP workers. */
export const readRegionBytes = (workers: i32): i32 => readRingAt(workers)

/** Writes the rings of `workers` HTTP workers into a fresh region. */
export const initReadRings = (region: SharedRegion, workers: i32): void => {
  for (let w: i32 = 0; w < workers; w++) {
    initSpscRing(region, readRingAt(w), READ_RING, false)
    initSpscRing(region, answerRingAt(w), ANSWER_RING, false)
  }
}

/** One side's view of the two rings of one HTTP worker. */
export class ReadLink {
  region: SharedRegion
  /** The ring this side pops, and the one it pushes. */
  rx: SpscRing
  tx: SpscRing
  /** The prefork channel to the other side. */
  fd: i32
  private readonly mine: i32
  private readonly peer: i32
  private pushed: boolean = false
  private readonly bell: u8[]

  constructor(region: SharedRegion, w: i32, fd: i32, service: boolean) {
    this.region = region
    this.fd = fd
    this.mine = service ? SERVICE_FLAG : workerFlag(w)
    this.peer = service ? workerFlag(w) : SERVICE_FLAG
    const reads: SpscRing = attachSpscRing(region, readRingAt(w)).expect("the read ring")
    const answers: SpscRing = attachSpscRing(region, answerRingAt(w)).expect("the answer ring")
    this.rx = service ? reads : answers
    this.tx = service ? answers : reads
    this.bell = new Array<u8>(64)
  }

  push(src: u8[], len: i32): boolean {
    if (!this.tx.tryPush(src, 0, len)) {
      return false
    }
    this.pushed = true
    return true
  }

  /** Wakes the other side if anything was pushed since it said it sleeps. */
  ring(): void {
    if (!this.pushed) {
      return
    }
    this.pushed = false
    fence(SEQ_CST)
    if (
      this.region.loadI32(this.peer, SEQ_CST) !== 0 &&
      this.region.exchangeI32(this.peer, 0, SEQ_CST) !== 0
    ) {
      netWrite(this.fd, this.bell, 0, 1)
    }
  }

  /** Says this side is about to sleep; the caller then looks at its rings once more. */
  sleeping(): void {
    this.region.storeI32(this.mine, 1, SEQ_CST)
    fence(SEQ_CST)
  }

  awake(): void {
    this.region.storeI32(this.mine, 0, RELAXED)
  }

  /** Takes the wake-ups from the channel; false once the other side is gone. */
  woken(): boolean {
    return netRead(this.fd, this.bell, 0, 64) > 0
  }
}
