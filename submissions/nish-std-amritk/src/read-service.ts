// The read service: one process that holds every read plan of the box. HTTP
// workers parse, check the token and write the answer; the reads a plan takes
// come to this process over rings (read-ring.ts), so two workers' reads share
// one plan and each key and article of a window is read once for both. It is
// what a single worker's queue would be, on a core that does not also serve
// connections.
//
// A plan opens with its first read and starts when it is full or its window
// ends. While every plan is busy reads wait in the rings, and a worker whose
// ring is full plans them itself. Nothing is kept between plans.
import { getI32LE, getI64LE } from "nish/bytes"
import {
  connectResult,
  netAddress,
  netClose,
  netRead,
  netWrite,
  pollAdd,
  pollCreate,
  pollModify,
  pollRemove,
  pollWait,
  tcpConnect,
} from "nish:net"
import { monotonicNanos } from "nish:process"
import { secret, wipe } from "nish:secret"
import { H1_WANT_READ, H1_WANT_WRITE } from "nish/net/http1-server"
import {
  PG_FAILED,
  PG_GROUP_DONE,
  PG_LOST,
  PG_NEED_MORE,
  PG_POOL_FULL,
  PgConnection,
  PgPool,
} from "nish/net/postgres"
import { RING_EMPTY, RING_TOO_SMALL } from "nish/sync/ring"
import { CountRun, PLAN_ALONE, ReadPlan } from "./plan"
import { ANSWER_ALONE, ANSWER_MAX, ANSWER_TAIL, READ_HEAD, ReadLink } from "./read-ring"
import { registerPlanStatements } from "./sql"
import { pgConfig, WorkerConfig } from "./worker"

const SERVICE_AGAIN: i32 = -11
const SERVICE_READABLE: i32 = 5
const SERVICE_TICKETS: i32 = 131072
const SERVICE_QUEUE: i32 = 65536
/** A plan's states: free, taking reads, full or due, its groups, or waiting for its counts. */
const S_FREE: i32 = 0
const S_OPEN: i32 = 1
const S_DUE: i32 = 2
const S_A: i32 = 3
const S_B: i32 = 4
/** Group B has ended and the plan waits only for its count run. */
const S_COUNT: i32 = 5
/** The plan's answers are going to the workers; a worker's full ring holds the rest back. */
const S_SEND: i32 = 6
/** How long an answer waits for room in a worker's ring, in ns, before that worker counts as stuck. */
const STUCK_NS: i64 = 5000000000
const WORKER_TAGS: i32 = 16

class ServiceSocket {
  fd: i32 = -1
  connected: boolean = false
  armed: i32 = 0
}

export class ReadService {
  loop: i32
  pool: PgPool
  sockets: ServiceSocket[]
  address: u8[]
  links: ReadLink[]
  plans: ReadPlan[]
  state: i32[]
  /** Per ticket: the plan whose group it is, `plans.length` for a count run not yet bound, past that a count run by place, or -1. */
  ticketPlan: i32[]
  /** Per ticket of a plan: the lane of the group it binds (ReadPlan.bindA and bindB). */
  ticketLane: i32[]
  /**
   * The count lanes: one run taking plans, up to `lanes` running, each on a
   * connection of its own, and whether a connection has been asked for. A
   * run takes about 45 ms at 175,000 users and plans read their articles
   * beside it, so one lane costs a read little; a second cost Postgres 9 µs a
   * request on the VM, in articles the runs no longer share.
   */
  countRuns: CountRun[]
  countBusy: boolean[]
  countOpen: i32 = 0
  lanes: i32
  running: i32 = 0
  asked: boolean = false
  /** The plan taking reads, or -1, and when its first came. */
  open: i32 = -1
  openedAt: i64 = 0
  /** Per plan: it waits for a count run still, and its connection was lost meanwhile. */
  counting: boolean[]
  lost: boolean[]
  /** Per plan: the lanes of its group still running, and whether a connection under one was lost. */
  lanesLeft: i32[]
  laneLost: boolean[]
  /** Per plan in S_SEND: the next answer to send, and since when a full ring has held it back (0: none has). */
  sendNext: i32[]
  sendHeld: i64[]
  sending: i32 = 0
  planMin: i32
  planWait: i64
  /** A read popped that its plan had no room for, and its worker; the next ring to look at. */
  rec: u8[]
  recLen: i32 = 0
  recFrom: i32 = 0
  nextLink: i32 = 0
  gone: boolean = false

  constructor(cfg: WorkerConfig, links: ReadLink[]) {
    this.links = links
    this.loop = pollCreate()
    const password = secret(serviceBytes(cfg.dbPassword))
    this.pool = new PgPool(pgConfig(cfg, cfg.readInFlight), password, cfg.readConns, SERVICE_QUEUE)
    wipe(password)
    this.sockets = []
    for (let s: i32 = 0; s < this.pool.size; s++) {
      this.sockets.push(new ServiceSocket())
    }
    this.address = new Array<u8>(18)
    netAddress(this.address, cfg.dbHost, cfg.dbPort)
    registerPlanStatements(this.pool)
    this.plans = []
    this.state = []
    this.counting = []
    this.lost = []
    this.lanesLeft = []
    this.laneLost = []
    this.sendNext = []
    this.sendHeld = []
    for (let k: i32 = 0; k < (cfg.readPlans > 0 ? cfg.readPlans : 1); k++) {
      this.plans.push(new ReadPlan())
      this.state.push(S_FREE)
      this.counting.push(false)
      this.lost.push(false)
      this.lanesLeft.push(0)
      this.laneLost.push(false)
      this.sendNext.push(0)
      this.sendHeld.push(toI64(0))
    }
    const noTypes: i32[] = []
    this.pool.register(this.plans[0].articles.name, this.plans[0].articles.sql, noTypes)
    this.pool.register(this.plans[0].comments.name, this.plans[0].comments.sql, noTypes)
    this.pool.register(this.plans[0].profiles.name, this.plans[0].profiles.sql, noTypes)
    this.ticketPlan = new Array<i32>(SERVICE_TICKETS)
    this.ticketLane = new Array<i32>(SERVICE_TICKETS)
    for (let k: i32 = 0; k < SERVICE_TICKETS; k++) {
      this.ticketPlan[k] = -1
    }
    this.lanes = cfg.countLanes > 0 ? cfg.countLanes : 1
    this.countRuns = []
    this.countBusy = []
    for (let k: i32 = 0; k <= this.lanes; k++) {
      this.countRuns.push(new CountRun())
      this.countBusy.push(false)
    }
    this.planMin = cfg.planMin
    this.planWait = toI64(cfg.planWaitUs) * 1000
    this.rec = new Array<u8>(READ_HEAD + 2048)
  }

  /** Serves until a worker goes; a worker that goes ends the server (the challenge restarts nothing). */
  run(): i32 {
    const ready: i32[] = new Array<i32>(2 * 256)
    for (let k: i32 = 0; k < toI32(this.links.length); k++) {
      pollAdd(this.loop, this.links[k].fd, H1_WANT_READ, -1 - k)
    }
    const link: ReadLink = this.links[0]
    while (!this.gone) {
      this.pump()
      let wait: i32 = 1000
      const left: i64 = this.waitLeft()
      if (left > 0) {
        const ms: i32 = toI32((left + 999999) / 1000000)
        wait = ms < wait ? ms : wait
      } else if (this.open >= 0) {
        wait = 0
      }
      if (this.sending > 0) {
        // A worker drains its ring every turn, paced: look again in a millisecond.
        wait = wait < 1 ? wait : 1
      }
      link.sleeping()
      if (this.take()) {
        wait = 0
      }
      const n: i32 = pollWait(this.loop, ready, wait)
      link.awake()
      if (n < 0 && n !== -4) {
        return 1
      }
      for (let k: i32 = 0; k < n; k++) {
        const token: i32 = ready[2 * k]
        if (token < 0) {
          this.gone = !this.links[-1 - token].woken() || this.gone
        } else if (token < this.pool.size) {
          this.pgReady(token, ready[2 * k + 1])
        }
      }
    }
    return 1
  }

  /** How long, in ns, the open plan may wait still. */
  waitLeft(): i64 {
    if (this.open < 0) {
      return 0
    }
    const left: i64 = this.openedAt + this.planWait - monotonicNanos()
    return left > 0 ? left : 0
  }

  freePlan(): i32 {
    for (let p: i32 = 0; p < toI32(this.state.length); p++) {
      if (this.state[p] === S_FREE) {
        return p
      }
    }
    return -1
  }

  /** The next read from the rings into `rec`, round the workers; false when none waits. */
  popRead(): boolean {
    const n: i32 = toI32(this.links.length)
    for (let k: i32 = 0; k < n; k++) {
      const at: i32 = (this.nextLink + k) % n
      const got: i32 = this.links[at].rx.tryPop(this.rec, 0)
      if (got > 0) {
        this.recLen = got
        this.recFrom = at
        this.nextLink = (at + 1) % n
        return true
      }
      if (got === RING_TOO_SMALL) {
        this.rec = new Array<u8>(2 * toI32(this.rec.length))
        k -= 1
      } else if (got !== RING_EMPTY) {
        return false
      }
    }
    return false
  }

  /** Moves reads from the rings into plans, while a plan is free; whether it moved any. */
  take(): boolean {
    let took: boolean = false
    while (this.recLen > 0 || this.popRead()) {
      if (this.open < 0) {
        const p: i32 = this.freePlan()
        if (p < 0) {
          return took
        }
        this.plans[p].reset()
        this.state[p] = S_OPEN
        this.open = p
        this.openedAt = monotonicNanos()
      }
      const b: u8[] = this.rec
      const tag: i32 = getI32LE(b, 0) * WORKER_TAGS + this.recFrom
      const added: boolean = this.plans[this.open].add(
        tag,
        getI32LE(b, 4),
        getI64LE(b, 16),
        getI64LE(b, 24),
        getI64LE(b, 32),
        b,
        READ_HEAD,
        getI32LE(b, 8)
      )
      if (added) {
        this.recLen = 0
        took = true
      } else {
        this.state[this.open] = S_DUE
        this.open = -1
      }
    }
    return took
  }

  pump(): void {
    if (this.sending > 0) {
      for (let p: i32 = 0; p < toI32(this.state.length); p++) {
        if (this.state[p] === S_SEND) {
          this.send(p)
        }
      }
    }
    this.take()
    if (this.open >= 0 && (this.plans[this.open].count >= this.planMin || this.waitLeft() === 0)) {
      this.state[this.open] = S_DUE
      this.open = -1
      this.take()
    }
    for (let p: i32 = 0; p < toI32(this.state.length); p++) {
      if (this.state[p] === S_DUE) {
        if (!this.askLanes(p, this.plans[p].lanesA())) {
          break
        }
        this.state[p] = S_A
      }
    }
    if (!this.asked && this.running < this.lanes && this.countRuns[this.countOpen].plans.length > 0) {
      const ticket: i32 = this.pool.request()
      if (ticket !== PG_POOL_FULL) {
        this.ticketPlan[ticket % SERVICE_TICKETS] = toI32(this.plans.length)
        this.asked = true
      }
    }
    let s: i32 = this.pool.dispatch()
    while (s >= 0) {
      this.bindGroup(this.pool.connection(s), this.pool.ticket % SERVICE_TICKETS)
      s = this.pool.dispatch()
    }
    s = this.pool.wanted()
    while (s >= 0 && s < this.pool.size) {
      const socket: ServiceSocket = this.sockets[s]
      const nonce = new Array<u8>(18)
      crypto.getRandomValues(nonce)
      this.pool.connect(s, nonce)
      socket.fd = tcpConnect(this.address)
      socket.connected = false
      socket.armed = H1_WANT_WRITE
      if (socket.fd < 0 || pollAdd(this.loop, socket.fd, H1_WANT_WRITE, s) < 0) {
        this.pool.connection(s).closed()
        this.pgEvents(s)
      }
      s = this.pool.wanted()
    }
    for (let k: i32 = 0; k < this.pool.size; k++) {
      const socket: ServiceSocket = this.sockets[k]
      if (socket.fd >= 0 && socket.connected) {
        const conn: PgConnection = this.pool.connection(k)
        if (!this.flush(conn, socket.fd)) {
          conn.closed()
          this.pgEvents(k)
        } else if (socket.fd >= 0) {
          const wants: i32 =
            conn.outputEnd() > conn.outputStart() ? H1_WANT_READ | H1_WANT_WRITE : H1_WANT_READ
          if (wants !== socket.armed) {
            socket.armed = wants
            pollModify(this.loop, socket.fd, wants, k)
          }
        }
      }
    }
    for (const link of this.links) {
      link.ring()
    }
  }

  /** Binds the group of the ticket at `at`: a plan's, or the count run's. */
  bindGroup(conn: PgConnection, at: i32): void {
    const pi: i32 = this.ticketPlan[at]
    if (pi === toI32(this.plans.length)) {
      // A count run: it takes every plan waiting now, and the next plans open a free one.
      const place: i32 = this.countOpen
      const run: CountRun = this.countRuns[place]
      this.countBusy[place] = true
      this.running += 1
      this.asked = false
      this.ticketPlan[at] = pi + 1 + place
      for (let k: i32 = 0; k < toI32(this.countBusy.length); k++) {
        if (!this.countBusy[k]) {
          this.countOpen = k
        }
      }
      const counted: boolean = run.bind(conn)
      if (!counted) {
        conn.bindCancel()
      }
      run.failed = !counted
      if (!this.pool.send()) {
        this.ticketPlan[at] = -1
        this.countsDone(place, true, false)
      }
      return
    }
    if (pi < 0) {
      return
    }
    const plan: ReadPlan = this.plans[pi]
    const lane: i32 = this.ticketLane[at]
    if (!(this.state[pi] === S_A ? plan.bindA(conn, lane) : plan.bindB(conn, lane))) {
      // The statements bound still run; the plan's requests go alone once they have.
      plan.failed = true
      conn.bindCancel()
    }
    if (!this.pool.send()) {
      this.ticketPlan[at] = -1
      plan.failed = true
      this.laneDone(pi)
    }
  }

  groupDone(p: i32): void {
    const plan: ReadPlan = this.plans[p]
    if (this.state[p] === S_A) {
      if (plan.failed) {
        plan.abortA()
      } else if (plan.planB()) {
        // Group B and the counts run side by side: the run joined is one
        // plans share, and a plan need not wait for it to read its articles.
        if (plan.metas > 0 && !this.countRuns[this.countOpen].join(p, plan)) {
          plan.failed = true
        } else if (this.askB(p)) {
          this.counting[p] = plan.metas > 0
          return
        } else if (plan.metas > 0) {
          // In the run already: its end finishes the plan.
          this.counting[p] = true
          this.state[p] = S_COUNT
          return
        }
      }
    } else if (this.counting[p]) {
      this.state[p] = S_COUNT
      return
    }
    this.finish(p, false)
  }

  askB(p: i32): boolean {
    if (!this.askLanes(p, this.plans[p].lanesB())) {
      this.plans[p].failed = true
      return false
    }
    this.state[p] = S_B
    return true
  }

  /**
   * Asks the pool for a connection for each lane of `lanes` (bit 0, bit 1) of
   * plan `p`'s next group, so its two halves run side by side; both on one
   * when the pool has room for only one, or the group has one lane. False
   * when it has room for none.
   */
  askLanes(p: i32, lanes: i32): boolean {
    const first: i32 = this.pool.request()
    if (first === PG_POOL_FULL) {
      return false
    }
    this.ticketPlan[first % SERVICE_TICKETS] = p
    this.laneLost[p] = false
    if (lanes !== 3) {
      this.ticketLane[first % SERVICE_TICKETS] = 2
      this.lanesLeft[p] = 1
      return true
    }
    const second: i32 = this.pool.request()
    if (second === PG_POOL_FULL) {
      this.ticketLane[first % SERVICE_TICKETS] = 2
      this.lanesLeft[p] = 1
      return true
    }
    this.ticketLane[first % SERVICE_TICKETS] = 0
    this.ticketPlan[second % SERVICE_TICKETS] = p
    this.ticketLane[second % SERVICE_TICKETS] = 1
    this.lanesLeft[p] = 2
    return true
  }

  /** Lane of plan `p` done; once its group's last is, the group is. */
  laneDone(p: i32): void {
    this.lanesLeft[p] -= 1
    if (this.lanesLeft[p] > 0) {
      return
    }
    if (!this.laneLost[p]) {
      this.groupDone(p)
      return
    }
    const plan: ReadPlan = this.plans[p]
    plan.abortA()
    if (this.counting[p]) {
      this.lost[p] = true
      this.state[p] = S_COUNT
    } else {
      this.finish(p, true)
    }
  }

  countsDone(place: i32, failed: boolean, lost: boolean): void {
    const run: CountRun = this.countRuns[place]
    this.countBusy[place] = false
    this.running -= 1
    for (const p of run.plans) {
      const plan: ReadPlan = this.plans[p]
      plan.failed = plan.failed || failed || lost || run.failed
      plan.takeCounts(run)
      this.counting[p] = false
      if (this.state[p] === S_COUNT) {
        this.finish(p, lost || this.lost[p])
      }
    }
    run.reset()
  }

  /** Sends plan `p`'s answers to its workers, and frees the plan once all have gone. */
  finish(p: i32, lost: boolean): void {
    this.lost[p] = lost
    this.sendNext[p] = 0
    this.sendHeld[p] = toI64(0)
    this.state[p] = S_SEND
    this.sending += 1
    this.send(p)
  }

  /**
   * Sends plan `p`'s answers from `sendNext[p]` on. An answer whose worker's
   * ring is full waits there, and the plan with it, for the next turn: the
   * service goes on reading and planning meanwhile instead of spinning. A
   * ring full for `STUCK_NS` means its worker is stuck, which ends the server.
   */
  send(p: i32): void {
    const plan: ReadPlan = this.plans[p]
    const lost: boolean = this.lost[p]
    for (let i: i32 = this.sendNext[p]; i < plan.count; i++) {
      let status: i32 = 500
      plan.outEnd = 0
      if (!lost) {
        status = plan.failed ? PLAN_ALONE : plan.render(i)
      }
      if (status !== 200 || plan.outEnd > ANSWER_MAX) {
        plan.outEnd = 0
        status = status === 200 || status === PLAN_ALONE ? ANSWER_ALONE : status
      }
      const tag: i32 = plan.tags[i]
      const len: i32 = plan.seal(tag / WORKER_TAGS, status, ANSWER_TAIL)
      const link: ReadLink = this.links[tag % WORKER_TAGS]
      if (!link.push(plan.out, len)) {
        link.ring()
        const now: i64 = monotonicNanos()
        if (this.sendHeld[p] === toI64(0)) {
          this.sendHeld[p] = now
        } else if (now - this.sendHeld[p] > STUCK_NS) {
          this.gone = true
        }
        this.sendNext[p] = i
        return
      }
      this.sendHeld[p] = toI64(0)
    }
    this.state[p] = S_FREE
    this.lost[p] = false
    this.sending -= 1
  }

  flush(conn: PgConnection, fd: i32): boolean {
    while (conn.outputEnd() > conn.outputStart()) {
      const n: i32 = netWrite(fd, conn.outputBuffer(), conn.outputStart(), conn.outputEnd() - conn.outputStart())
      if (n === SERVICE_AGAIN) {
        return true
      }
      if (n <= 0) {
        return false
      }
      conn.sent(n)
    }
    return true
  }

  pgReady(s: i32, events: i32): void {
    const socket: ServiceSocket = this.sockets[s]
    if (socket.fd < 0) {
      return
    }
    const conn: PgConnection = this.pool.connection(s)
    if (!socket.connected) {
      if (connectResult(socket.fd) === 0) {
        socket.connected = true
      } else {
        conn.closed()
      }
      this.pgEvents(s)
      return
    }
    if ((events & SERVICE_READABLE) !== 0) {
      while (true) {
        let room: i32 = conn.inputRoom()
        if (room <= 0) {
          this.pgEvents(s)
          if (socket.fd < 0) {
            return
          }
          room = conn.inputRoom()
          if (room <= 0) {
            break
          }
        }
        const got: i32 = netRead(socket.fd, conn.inputBuffer(), conn.inputEnd(), room)
        if (got === SERVICE_AGAIN) {
          break
        }
        if (got <= 0) {
          conn.closed()
          break
        }
        conn.received(got)
        if (got < room) {
          break
        }
        this.pgEvents(s)
        if (socket.fd < 0) {
          return
        }
      }
    }
    this.pgEvents(s)
  }

  pgEvents(s: i32): void {
    const conn: PgConnection = this.pool.connection(s)
    let event: i32 = this.pool.next(s)
    while (event !== PG_NEED_MORE) {
      if (event === PG_FAILED) {
        const socket: ServiceSocket = this.sockets[s]
        if (socket.fd >= 0) {
          pollRemove(this.loop, socket.fd)
          netClose(socket.fd)
          socket.fd = -1
          socket.connected = false
        }
        return
      }
      const ticket: i32 = this.pool.ticket
      if (ticket >= 0 && this.ticketPlan[ticket % SERVICE_TICKETS] >= 0) {
        this.planEvent(ticket % SERVICE_TICKETS, conn, event)
      }
      event = this.pool.next(s)
    }
  }

  planEvent(at: i32, conn: PgConnection, event: i32): void {
    const p: i32 = this.ticketPlan[at]
    if (p >= toI32(this.plans.length)) {
      const place: i32 = p - toI32(this.plans.length) - 1
      if (place < 0) {
        // Lost before it was bound.
        this.ticketPlan[at] = -1
        this.asked = false
      } else if (event === PG_LOST || event === PG_GROUP_DONE) {
        this.ticketPlan[at] = -1
        this.countsDone(place, event === PG_LOST || conn.groupFailed, event === PG_LOST)
      } else {
        this.countRuns[place].event(conn, event)
      }
      return
    }
    const plan: ReadPlan = this.plans[p]
    if (event === PG_LOST) {
      this.ticketPlan[at] = -1
      plan.failed = true
      this.laneLost[p] = true
      this.laneDone(p)
    } else if (event === PG_GROUP_DONE) {
      this.ticketPlan[at] = -1
      if (conn.groupFailed) {
        plan.failed = true
      }
      this.laneDone(p)
    } else if (this.state[p] === S_A) {
      plan.eventA(conn, event, this.ticketLane[at])
    } else {
      plan.eventB(conn, event, this.ticketLane[at])
    }
  }
}

const serviceBytes = (s: string): u8[] => {
  const out: u8[] = new Array<u8>(s.length)
  for (let k: i32 = 0; k < toI32(s.length) && k < toI32(out.length); k++) {
    out[k] = toU8(s.charCodeAt(k))
  }
  return out
}
