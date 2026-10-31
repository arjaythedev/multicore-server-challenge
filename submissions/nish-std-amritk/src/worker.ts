// One HTTP worker: a single-threaded `pollWait` loop holding its share of the
// listener (SO_REUSEPORT), every keep-alive connection the kernel gives it,
// two `PgPool`s (reads and writes) and one connection to each bcrypt service.
// It is tests/postgres/carrier.ts's shape, with the Conduit API on top.
//
// A request is parsed when its head arrives and checked when its body ends:
// the route, the token's signature and `exp`, the query, the JSON body. One
// that passes becomes a ticket on a pool; the pool hands it to a connection
// with room, the worker binds its statements as one pipelined group, and the
// response is written from the rows as they arrive, straight from the input
// buffer into that connection's JSON writer. It goes to the client once the
// group's ReadyForQuery says its implicit transaction committed (the
// challenge's rule 6). A request the connection lost answers 500 and is never
// sent again: a lost write may have committed. The reads that most requests
// are (the tag list, list pages, feeds, articles and comments) wait instead
// for a read plan (plan.ts), which answers all those waiting together from a
// few statements over their distinct keys; writes wait for a group commit.
//
// Memory: a request's state is a `ConduitReq` from a free list, its strings
// spans of the request's own byte array; the JSON writers write into one
// buffer per Postgres connection, and each read plan into buffers of its own
// that it reuses; nothing is allocated per request once the worker has
// served its peak.
import {
  NET_TCP_QUICKACK,
  connectResult,
  netAddress,
  netClose,
  netRead,
  netSetOption,
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
import {
  H1_BODY,
  H1_DONE,
  H1_END,
  H1_ERROR,
  H1_NEED_MORE,
  H1_POOL_FULL,
  H1_REQUEST,
  H1_WANT_READ,
  H1_WANT_WRITE,
  Http1Config,
  Http1Connection,
  Http1Server,
} from "nish/net/http1-server"
import { HTTP1_NO_BODY, Http1Parser } from "nish/net/http1"
import { HTTP_CODING_IDENTITY, HttpCompressor } from "nish/net/http-compress"
import { DEFLATE_FAST } from "nish/compress/deflate"
import { JsonWriter } from "nish/json"
import {
  JSON_TOK_ARRAY_BEGIN,
  JSON_TOK_ARRAY_END,
  JSON_TOK_END,
  JSON_TOK_KEY,
  JSON_TOK_NULL,
  JSON_TOK_OBJECT_BEGIN,
  JSON_TOK_OBJECT_END,
  JSON_TOK_STRING,
  JsonLimits,
  JsonTokenizer,
} from "nish/json-tokenizer"
import {
  PG_ARRAY_ELEMENT,
  PG_ARRAY_NULL,
  PG_COMPLETE,
  PG_ERROR,
  PG_FAILED,
  PG_GROUP_DONE,
  PG_LOST,
  PG_NEED_MORE,
  PG_POOL_FULL,
  PG_ROW,
  PgArrayWalker,
  PgConfig,
  PgConnection,
  PgPool,
} from "nish/net/postgres"
import {
  BCRYPT_DONE,
  BCRYPT_MAX_PASSWORD,
  BCRYPT_OP_HASH,
  BCRYPT_OP_VERIFY,
  BcryptClient,
} from "./bcrypt-service"
import {
  jsonOutBool,
  jsonOutNull,
  jsonOutRaw,
  jsonOutString,
  jsonOutTextArray,
  jsonOutWorst,
} from "./json-out"
import { Jwt, jwtDigits } from "./jwt"
import {
  K_ARTICLE,
  K_AUTHOR,
  K_COMMENTS,
  K_FAVORITED,
  K_FEED,
  K_GLOBAL,
  K_PROFILE,
  K_TAG,
  K_TAGS,
  PLAN_ALONE,
  CountRun,
  ReadPlan,
} from "./plan"
import {
  COL_BIO,
  COL_BODY,
  COL_CREATED,
  COL_DESCRIPTION,
  COL_FAVORITED,
  COL_FAVORITES,
  COL_FOLLOWING,
  COL_IMAGE,
  COL_SLUG,
  COL_TAGS,
  COL_TITLE,
  COL_UPDATED,
  COL_USERNAME,
  registerPlanStatements,
  registerStatements,
} from "./sql"

// ---- Routes ---------------------------------------------------------------------

const R_NONE: i32 = 0
const R_TAGS: i32 = 1
const R_SIGNUP: i32 = 2
const R_LOGIN: i32 = 3
const R_USER_GET: i32 = 4
const R_USER_PUT: i32 = 5
const R_PROFILE: i32 = 6
const R_FOLLOW: i32 = 7
const R_UNFOLLOW: i32 = 8
const R_LIST: i32 = 9
const R_FEED: i32 = 10
const R_ARTICLE_GET: i32 = 11
const R_ARTICLE_CREATE: i32 = 12
const R_ARTICLE_PUT: i32 = 13
const R_ARTICLE_DELETE: i32 = 14
const R_FAVORITE: i32 = 15
const R_UNFAVORITE: i32 = 16
const R_COMMENTS: i32 = 17
const R_COMMENT_CREATE: i32 = 18
const R_COMMENT_DELETE: i32 = 19

/** The list filters, in the order SPEC.md lets the first one win. */
const FILTER_NONE: i32 = 0
const FILTER_TAG: i32 = 1
const FILTER_AUTHOR: i32 = 2
const FILTER_FAVORITED: i32 = 3

// The request's strings: each a span of `ConduitReq.text`, -1 long when absent or null.
const F_USERNAME: i32 = 0
const F_EMAIL: i32 = 1
const F_BIO: i32 = 2
const F_IMAGE: i32 = 3
const F_TITLE: i32 = 4
const F_DESCRIPTION: i32 = 5
const F_BODY: i32 = 6
/** A path segment: the slug, or the profile's username. */
const F_PATH: i32 = 7
/** The list filter's value. */
const F_FILTER: i32 = 8
/** The token the request presented, which GET and PUT /api/user answer with. */
const F_TOKEN: i32 = 9
/** A stored or new bcrypt hash. */
const F_HASH: i32 = 10
/** The tags of a new article, as a `text[]` literal. */
const F_TAGS: i32 = 11
const F_COUNT: i32 = 12
/** Not a span: the body's `password`, which goes to `ConduitReq.pw`. */
const F_PASSWORD: i32 = 100
/** Not a span: the body's `tagList`. */
const F_TAGLIST: i32 = 101

// Which body fields a route reads, as bits of the field numbers above (password 1 << 12, tagList 1 << 13).
const BIT_PASSWORD: i32 = 4096
const BIT_TAGLIST: i32 = 8192
const FIELDS_SIGNUP: i32 = 4099 // username, email, password
const FIELDS_LOGIN: i32 = 4098 // email, password
const FIELDS_USER: i32 = 4111 // username, email, bio, image, password
const FIELDS_ARTICLE: i32 = 8304 // title, description, body, tagList
const FIELDS_COMMENT: i32 = 64 // body

const POOL_READ: i32 = 0
const POOL_WRITE: i32 = 1

/** Tokens in the loop: the listener, the bcrypt services (-2 down), then pool slots below; HTTP slots are 0 and up. */
const TOKEN_LISTENER: i32 = -1
const TOKEN_BCRYPT: i32 = -2
const TOKEN_POOL: i32 = -16
/** The most bcrypt services a worker connects to: the tokens between `TOKEN_BCRYPT` and `TOKEN_POOL`. */
export const BCRYPT_SERVICES_MAX: i32 = 14
const POOL_TOKENS: i32 = 1024

const AGAIN: i32 = -11
const READABLE: i32 = 5
/** The ring that maps a pool's tickets to requests: a power of two above the queue and the groups in flight. */
const TICKET_RING: i32 = 131072
const QUEUE: i32 = 65536
/** The most writes one group commits together. */
const WRITE_BATCH: i32 = 128
/** A read plan's states: free, its group A or group B asked of the pool, or sent. */
const PLAN_FREE: i32 = 0
const PLAN_A: i32 = 1
const PLAN_B: i32 = 2
/** The plan waits for its favorite counts, between group A and group B. */
const PLAN_COUNT: i32 = 3
/** The longest key (a tag, a username, a slug) a read plan takes; a longer one is read alone. */
const PLAN_KEY_MAX: i32 = 1024
/**
 * The most bytes a batch's binds may take, half of `PG_MAX_OUTPUT`. One
 * write's binds take at most twice its text (tags are bound twice) and 512
 * bytes, `writeCost`.
 */
const WRITE_BATCH_BYTES: i32 = 2097152
/** The connections' `maxOutput`: what may wait unsent on one of them. */
const PG_MAX_OUTPUT: i32 = 4194304
/** The largest response body a writer holds; the output buffer holds it and its head. */
const RESPONSE_ROOM: i32 = 1048576
/** How long the worker waits for the bcrypt service to listen before failing the logins that wait, in ns. */
const BCRYPT_PATIENCE: i64 = 5000000000

/** At most the bytes `r`'s binds take: twice its text (tags are bound twice) and 512. */
const writeCost = (r: ConduitReq): i32 => 2 * r.textEnd + 512
/** Whether `b[start, end)` is UTF-8 with no NUL: a text a read plan takes as a key, and Postgres as text. */
const isText = (b: u8[], start: i32, end: i32): boolean => {
  let k: i32 = start
  while (k < end && k < toI32(b.length)) {
    const c: i32 = toI32(b[k])
    if (c === 0) {
      return false
    }
    if (c < 128) {
      k++
      continue
    }
    // The sequence's length, and the bounds of its second byte, which rule
    // out overlong forms, surrogates and code points past U+10FFFF.
    let n: i32 = 0
    let lo: i32 = 128
    let hi: i32 = 191
    if (c >= 194 && c <= 223) {
      n = 1
    } else if (c >= 224 && c <= 239) {
      n = 2
      lo = c === 224 ? 160 : 128
      hi = c === 237 ? 159 : 191
    } else if (c >= 240 && c <= 244) {
      n = 3
      lo = c === 240 ? 144 : 128
      hi = c === 244 ? 143 : 191
    } else {
      return false
    }
    if (n > end - k - 1) {
      return false
    }
    for (let j: i32 = 1; j <= n; j++) {
      const d: i32 = toI32(b[k + j])
      if (d < (j === 1 ? lo : 128) || d > (j === 1 ? hi : 191)) {
        return false
      }
    }
    k += n + 1
  }
  return true
}

/** One request in progress: its route, its parameters, and where its answer stands. */
class ConduitReq {
  index: i32 = 0
  /** The HTTP slot, and the slot's generation when the request came, so a closed and reused slot is told apart. */
  slot: i32 = -1
  gen: i32 = 0
  route: i32 = 0
  phase: i32 = 0
  viewer: i64 = 0
  /** A status to answer once the body has ended, or 0. */
  status: i32 = 0
  /** What the request's `Accept-Encoding` takes (`httpAcceptEncoding`). */
  coding: i32 = 0
  text: u8[]
  textEnd: i32 = 0
  fStart: i32[]
  fLen: i32[]
  body: u8[]
  bodyLen: i32 = 0
  /** The body's password, at most 72 bytes; -1 when none, 73 when too long. Wiped once sent. */
  pw: u8[]
  pwLen: i32 = -1
  tags: i32 = 0
  badTags: boolean = false
  limit: i64 = 20
  offset: i64 = 0
  filter: i32 = 0
  commentId: i64 = 0
  articleId: i64 = 0
  authorId: i64 = 0
  userId: i64 = 0
  /** The pool the request's group runs on, and its ticket there, while it has one. */
  pool: i32 = -1
  ticket: i32 = -1
  inPool: boolean = false
  inBcrypt: boolean = false
  /** Statements of the group answered so far. */
  stmt: i32 = 0
  found: boolean = false
  count: i64 = 0
  /** 0, or 23505's 1, or any other SQLSTATE's 2. */
  pgError: i32 = 0
  /** In a write batch: the next request of the batch, or -1 after the last. */
  batchNext: i32 = -1
  /** A write sent alone, after its batch failed; a read sent alone, outside a read plan. */
  solo: boolean = false
  /** A favorite or unfavorite whose write its batch's `favorite_many` or `unfavorite_many` makes: it reads its article only. */
  folded: boolean = false
  /** On a batch's first request: how many statements bound before its own, which answer no request. */
  prefix: i32 = 0
  /** The bcrypt service its password went to, while `inBcrypt`. */
  bcryptAt: i32 = -1
  /** A batched write's own answer: its writer and the buffer it writes. */
  own: u8[]
  ownWriter: JsonWriter

  constructor(index: i32) {
    this.index = index
    this.own = new Array<u8>(0)
    this.ownWriter = new JsonWriter(this.own, 0)
    this.text = new Array<u8>(512)
    this.fStart = new Array<i32>(F_COUNT)
    this.fLen = new Array<i32>(F_COUNT)
    this.body = new Array<u8>(256)
    this.pw = new Array<u8>(BCRYPT_MAX_PASSWORD + 1)
  }

  /** Puts the request back as new for slot `slot`, keeping its arrays. */
  restart(slot: i32, gen: i32): void {
    this.slot = slot
    this.gen = gen
    this.route = R_NONE
    this.phase = 0
    this.viewer = 0
    this.status = 0
    this.textEnd = 0
    for (let k: i32 = 0; k < F_COUNT; k++) {
      this.fStart[k] = 0
      this.fLen[k] = -1
    }
    this.bodyLen = 0
    this.pwLen = -1
    this.tags = 0
    this.badTags = false
    this.limit = 20
    this.offset = 0
    this.filter = FILTER_NONE
    this.commentId = 0
    this.articleId = 0
    this.authorId = 0
    this.userId = 0
    this.pool = -1
    this.ticket = -1
    this.inPool = false
    this.inBcrypt = false
    this.stmt = 0
    this.found = false
    this.count = 0
    this.pgError = 0
    this.batchNext = -1
    this.solo = false
    this.folded = false
    this.prefix = 0
  }

  /**
   * Makes `own` hold at least `n` bytes and starts `ownWriter` on it again:
   * a batched write's answer is `{` and one row, so it is sized when the row
   * comes, before any of it is written.
   */
  ownRoom(n: i32): void {
    if (toI32(this.own.length) < n) {
      let size: i32 = toI32(this.own.length) < 4096 ? 4096 : toI32(this.own.length)
      while (size < n) {
        size = size * 2
      }
      this.own = new Array<u8>(size)
    }
    this.ownWriter.reset(this.own, 0)
  }

  /** Makes room for `n` more bytes of `text`. */
  room(n: i32): void {
    if (this.textEnd + n <= toI32(this.text.length)) {
      return
    }
    let size: i32 = toI32(this.text.length) * 2
    while (size < this.textEnd + n) {
      size = size * 2
    }
    const grown: u8[] = new Array<u8>(size)
    for (let k: i32 = 0; k < this.textEnd; k++) {
      grown[k] = this.text[k]
    }
    this.text = grown
  }

  /** Appends `src[off, off + len)` to `text` as field `f`. */
  setField(f: i32, src: u8[], off: i32, len: i32): void {
    this.room(len)
    for (let k: i32 = 0; k < len; k++) {
      this.text[this.textEnd + k] = src[off + k]
    }
    this.fStart[f] = this.textEnd
    this.fLen[f] = len
    this.textEnd += len
  }

  /** Appends `src[off, off + len)` to the body. */
  addBody(src: u8[], off: i32, len: i32): void {
    if (this.bodyLen + len > toI32(this.body.length)) {
      let size: i32 = toI32(this.body.length) * 2
      while (size < this.bodyLen + len) {
        size = size * 2
      }
      const grown: u8[] = new Array<u8>(size)
      for (let k: i32 = 0; k < this.bodyLen; k++) {
        grown[k] = this.body[k]
      }
      this.body = grown
    }
    for (let k: i32 = 0; k < len; k++) {
      this.body[this.bodyLen + k] = src[off + k]
    }
    this.bodyLen += len
  }
}

/** A pool slot's socket, and the interest the loop last armed it with. */
class PgSocket {
  fd: i32 = -1
  connected: boolean = false
  armed: i32 = 0
}

/** The value of hex digit `c`, or -1. */
const hexValue = (c: i32): i32 => {
  if (c >= 48 && c <= 57) {
    return c - 48
  }
  if (c >= 97 && c <= 102) {
    return c - 87
  }
  if (c >= 65 && c <= 70) {
    return c - 55
  }
  return -1
}

/** Whether `b[start, end)` is exactly the ASCII `s`. */
const bytesAre = (b: u8[], start: i32, end: i32, s: string): boolean => {
  if (end - start !== toI32(s.length)) {
    return false
  }
  for (let k: i32 = 0; k < end - start; k++) {
    if (toI32(b[start + k]) !== toI32(s.charCodeAt(k))) {
      return false
    }
  }
  return true
}

/** `b[start, end)` as a non-negative decimal of at most 10 digits, leading zeros allowed; -1 otherwise. */
const decimalOf = (b: u8[], start: i32, end: i32): i64 => {
  if (end <= start) {
    return -1
  }
  let v: i64 = 0
  for (let k: i32 = start; k < end; k++) {
    const d: i32 = toI32(b[k]) - 48
    if (d < 0 || d > 9) {
      return -1
    }
    // Past 17 digits the next one could overflow; nothing here is that big.
    if (v > toI64(999999999) * 100000000) {
      return -1
    }
    v = v * 10 + toI64(d)
  }
  return v
}

const bytesOf = (s: string): u8[] => {
  const out: u8[] = new Array<u8>(s.length)
  for (let k: i32 = 0; k < toI32(s.length) && k < toI32(out.length); k++) {
    out[k] = toU8(s.charCodeAt(k))
  }
  return out
}

/** The worker's settings, from the environment `main.ts` reads. */
export class WorkerConfig {
  host: string = "0.0.0.0"
  port: i32 = 3000
  dbHost: string = "127.0.0.1"
  dbPort: i32 = 5432
  dbUser: string = "conduit"
  dbPassword: string = "conduit"
  dbName: string = "conduit"
  readConns: i32 = 3
  writeConns: i32 = 1
  maxInFlight: i32 = 16
  /**
   * The read pool's own `maxInFlight`. `PgPool` opens its next connection only once more than this many
   * groups per open connection wait, so with 4 the second read connection opens past 4 groups in flight
   * and the third past 8. The read plans (`readPlans`, 3) hold at most one group each, so the third opens
   * only when the plans and the reads made alone are busy at once.
   */
  readInFlight: i32 = 4
  /** How many read plans a worker has in flight at once (main.ts: one a read connection). */
  readPlans: i32 = 3
  /**
   * A plan starts once this many reads wait (a full plan), or once the
   * oldest has waited `planWaitUs`: a batch clock. With `planClock` off, the
   * window applies only while another plan is in flight.
   */
  planMin: i32 = 512
  planWaitUs: i32 = 10000
  /** 0: no clock; 1: the clock; 2: the clock only while at least `planLight` reads come a window. */
  planClock: i32 = 1
  planLight: i32 = 32
  bcryptPort: i32 = 47391
  /** How many bcrypt services listen, on `bcryptPort` and up. */
  bcryptServices: i32 = 1
  /** The jobs one of their calls takes. */
  bcryptWidth: i32 = 4
  slots: i32 = 200000
  backlog: i32 = 65535
  idleTimeoutMs: i32 = 75000
  /** Whether each answered connection goes back to delayed ACKs (`ConduitWorker.ackDelay`). */
  ackDelay: boolean = true
  /** 0: no gzip; 1: gzip a body when that sends fewer TCP segments; 2: whenever it saves anything. */
  gzip: i32 = 0
  /** The shortest body gzip is tried on. */
  gzipMin: i32 = 1300
}

/** A pool's connection settings, with up to `maxInFlight` groups in flight on each connection. */
const pgConfig = (cfg: WorkerConfig, maxInFlight: i32): PgConfig => {
  const config = new PgConfig()
  config.user = cfg.dbUser
  config.database = cfg.dbName
  config.applicationName = "conduit-nish"
  // Session settings at startup, for every connection: generic plans for
  // the prepared statements, no JIT and no parallel workers (one request
  // is small), no Memoize (a generic plan put one on the comment authors'
  // lookup, whose cache is emptied every execution: 2 hits in 351, and the
  // comments statement 7-12% slower with it), and the ISO and UTC spelling
  // the connection reads.
  config.options =
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off -c DateStyle=ISO -c TimeZone=UTC"
  config.maxInFlight = maxInFlight
  config.inputSize = 65536
  config.maxOutput = PG_MAX_OUTPUT
  return config
}

export class ConduitWorker {
  server: Http1Server
  loop: i32 = -1
  listener: i32 = -1
  jwt: Jwt
  pools: PgPool[]
  sockets: PgSocket[][]
  /** Per pool slot: the JSON writer the rows of its current group are written with, and the ticket that group is. */
  writers: JsonWriter[][]
  buffers: u8[][][]
  current: i32[][]
  /** Per pool: which request each ticket in flight is, by `ticket % TICKET_RING`. */
  tickets: i32[][]
  pgAddress: u8[]
  reqs: ConduitReq[]
  free: i32[]
  /** Per HTTP slot: its request in progress (-1 for none) and its generation. */
  slotReq: i32[]
  slotGen: i32[]
  /** Per HTTP slot: an answer was written since its last flush (`ackDelayAfter`). */
  slotAnswered: boolean[]
  /** `WorkerConfig.bcryptWidth`. */
  bcryptWidth: i32 = 4
  /** Gzips a JSON body when `WorkerConfig.gzip` asks; null otherwise. */
  gzip: HttpCompressor | null = null
  /** `WorkerConfig.ackDelay`, off for the process once the kernel refuses the option. */
  ackDelay: boolean = true
  jsonNames: u8[][]
  jsonValues: u8[][]
  noNames: u8[][]
  /** The writer of answers made without a group: errors, and a login after its bcrypt check. */
  plain: JsonWriter
  plainBuf: u8[]
  tokenizer: JsonTokenizer
  walker: PgArrayWalker
  stamp: u8[]
  scratch: u8[]
  /** Where `articleBytes` writes one article, and the fixed text it copies in. */
  rowBuf: u8[]
  fragments: u8[][]
  stringColumns: i32[]
  tokenBuf: u8[]
  /** One client a bcrypt service. */
  bcrypts: BcryptClient[]
  /** Requests answered, for a reader of `/proc`. */
  answered: i64 = 0
  /** Writes waiting for the next batch, a ring oldest first; and how many batches are in flight. */
  writeRing: i32[]
  writeHead: i32 = 0
  writeCount: i32 = 0
  writeBatches: i32 = 0
  /** The chains of writes `bindAll` held back this pump, by their first request. */
  deferred: i32[]
  /** Per write-pool slot: the request of its batch whose statements are being answered, and the batch's statements before it left. */
  writeCursor: i32[]
  writePrefix: i32[]
  /** The read plans, each one's `PLAN_` state, and the reads waiting for the next, a ring oldest first. */
  plans: ReadPlan[]
  planState: i32[]
  /** The count lane (plan.ts `CountRun`): the run plans join, the one running, and whether one runs or is asked for. */
  countRuns: CountRun[]
  countOpen: i32 = 0
  countBusy: boolean = false
  planRing: i32[]
  planHead: i32 = 0
  planCount: i32 = 0
  /** Per read-pool ticket, by `ticket % TICKET_RING`: the plan whose group it is, or -1. */
  ticketPlan: i32[]
  /** When each read in `planRing` came, in ns, by its place in the ring; and the start policy. */
  planAt: i64[]
  planMin: i32 = 512
  planWait: i64 = 0
  /** Whether the window gathers reads even while no plan runs: a batch clock (`WorkerConfig.planClock`). */
  planClock: i32 = 1
  planLight: i64 = 32
  /** Reads that came for plans since `rateAt`, and how many came a window over the last measure. */
  arrivals: i64 = 0
  rateAt: i64 = 0
  perWindow: i64 = 0

  constructor(cfg: WorkerConfig, listener: i32) {
    this.listener = listener
    const http = new Http1Config()
    http.idleTimeout = cfg.idleTimeoutMs
    http.maxBody = 1048576
    http.outputSize = RESPONSE_ROOM + 4096
    // Most of the challenge's tens of thousands of connections sit between
    // requests: they hold no input or head buffer while they do.
    http.idleInput = true
    this.server = new Http1Server(http, listener, cfg.slots)
    this.loop = pollCreate()
    pollAdd(this.loop, listener, H1_WANT_READ, TOKEN_LISTENER)
    this.jwt = new Jwt(bytesOf(getenv("JWT_SECRET") ?? ""))
    // The read pool opens a connection only once more groups wait than its
    // open connections may have in flight; coalesced, the reads queue few
    // groups, so its cap is its own.
    const password = secret(bytesOf(cfg.dbPassword))
    this.pools = [
      new PgPool(pgConfig(cfg, cfg.readInFlight), password, cfg.readConns, QUEUE),
      new PgPool(pgConfig(cfg, cfg.maxInFlight), password, cfg.writeConns, QUEUE),
    ]
    wipe(password)
    this.sockets = []
    this.writers = []
    this.buffers = []
    this.current = []
    this.tickets = []
    for (let p: i32 = 0; p < 2; p++) {
      const pool: PgPool = this.pools[p]
      registerStatements(pool)
      const socks: PgSocket[] = []
      const ws: JsonWriter[] = []
      const bufs: u8[][] = []
      const cur: i32[] = []
      for (let s: i32 = 0; s < pool.size; s++) {
        socks.push(new PgSocket())
        const buf: u8[] = new Array<u8>(RESPONSE_ROOM)
        bufs.push(buf)
        ws.push(new JsonWriter(buf, 0))
        cur.push(-1)
      }
      this.sockets.push(socks)
      this.writers.push(ws)
      this.buffers.push(bufs)
      this.current.push(cur)
      this.tickets.push(new Array<i32>(TICKET_RING))
    }
    this.pgAddress = new Array<u8>(18)
    netAddress(this.pgAddress, cfg.dbHost, cfg.dbPort)
    this.reqs = []
    this.free = []
    this.slotReq = new Array<i32>(cfg.slots)
    this.slotGen = new Array<i32>(cfg.slots)
    this.slotAnswered = new Array<boolean>(cfg.slots)
    this.ackDelay = cfg.ackDelay
    this.bcryptWidth = cfg.bcryptWidth
    if (cfg.gzip !== 0) {
      const enc: HttpCompressor = new HttpCompressor(DEFLATE_FAST, cfg.gzipMin, RESPONSE_ROOM)
      enc.segmentMode = cfg.gzip === 1
      this.gzip = enc
    }
    for (let k: i32 = 0; k < cfg.slots; k++) {
      this.slotReq[k] = -1
    }
    this.jsonNames = [bytesOf("Content-Type")]
    this.jsonValues = [bytesOf("application/json")]
    this.noNames = []
    this.plainBuf = new Array<u8>(8192)
    this.plain = new JsonWriter(this.plainBuf, 0)
    const limits = new JsonLimits()
    limits.maxDepth = 8
    this.tokenizer = new JsonTokenizer(this.plainBuf, 0, 0, limits)
    this.walker = new PgArrayWalker()
    this.stamp = new Array<u8>(24)
    this.scratch = new Array<u8>(65536)
    this.rowBuf = new Array<u8>(RESPONSE_ROOM)
    this.fragments = [
      bytesOf('{"slug":'),
      bytesOf(',"title":'),
      bytesOf(',"description":'),
      bytesOf(',"body":'),
      bytesOf(',"tagList":'),
      bytesOf(',"createdAt":"'),
      bytesOf('","updatedAt":"'),
      bytesOf('","favorited":'),
      bytesOf(',"favoritesCount":'),
      bytesOf(',"author":{"username":'),
      bytesOf(',"bio":'),
      bytesOf(',"image":'),
      bytesOf(',"following":'),
      bytesOf("}}"),
    ]
    this.stringColumns = [COL_SLUG, COL_TITLE, COL_DESCRIPTION, COL_BODY, COL_USERNAME, COL_BIO, COL_IMAGE]
    this.tokenBuf = new Array<u8>(512)
    this.bcrypts = []
    const services: i32 = cfg.bcryptServices < 1 ? 1 : cfg.bcryptServices > BCRYPT_SERVICES_MAX ? BCRYPT_SERVICES_MAX : cfg.bcryptServices
    for (let k: i32 = 0; k < services; k++) {
      const c = new BcryptClient()
      netAddress(c.address, "127.0.0.1", cfg.bcryptPort + k)
      this.bcrypts.push(c)
    }
    this.writeRing = new Array<i32>(QUEUE)
    this.deferred = []
    this.writeCursor = new Array<i32>(this.pools[POOL_WRITE].size)
    this.writePrefix = new Array<i32>(this.pools[POOL_WRITE].size)
    registerPlanStatements(this.pools[POOL_READ])
    this.plans = []
    this.planState = []
    this.countRuns = [new CountRun(), new CountRun()]
    for (let k: i32 = 0; k < (cfg.readPlans > 0 ? cfg.readPlans : 1); k++) {
      this.plans.push(new ReadPlan())
      this.planState.push(PLAN_FREE)
    }
    // Every plan's slug batchers bind the same two statements.
    const noTypes: i32[] = []
    this.pools[POOL_READ].register(this.plans[0].articles.name, this.plans[0].articles.sql, noTypes)
    this.pools[POOL_READ].register(this.plans[0].comments.name, this.plans[0].comments.sql, noTypes)
    this.pools[POOL_READ].register(this.plans[0].profiles.name, this.plans[0].profiles.sql, noTypes)
    this.planRing = new Array<i32>(QUEUE)
    this.planAt = new Array<i64>(QUEUE)
    this.planMin = cfg.planMin
    this.planWait = toI64(cfg.planWaitUs) * 1000
    this.planClock = cfg.planClock
    this.planLight = toI64(cfg.planLight)
    this.ticketPlan = new Array<i32>(TICKET_RING)
    for (let k: i32 = 0; k < TICKET_RING; k++) {
      this.ticketPlan[k] = -1
    }
  }

  // ---- The loop -------------------------------------------------------------------

  /** Serves until the process is stopped; answers 1 when the loop fails. */
  run(): i32 {
    const ready: i32[] = new Array<i32>(2 * 512)
    this.bcryptStart()
    while (true) {
      this.pump()
      let wait: i32 = 1000
      for (const c of this.bcrypts) {
        wait = c.retryAt > 0 ? 50 : wait
      }
      const left: i64 = this.planWaitLeft()
      if (left > 0) {
        // Woken when the oldest read's window ends, to the millisecond above.
        const ms: i32 = toI32((left + 999999) / 1000000)
        wait = ms < wait ? ms : wait
      }
      const n: i32 = pollWait(this.loop, ready, wait)
      if (n < 0 && n !== -4) {
        return 1
      }
      for (let k: i32 = 0; k < n; k++) {
        this.ready(ready[2 * k], ready[2 * k + 1])
      }
      this.server.expire(monotonicNanos())
      this.bcryptTick()
    }
  }

  /** One ready descriptor. */
  ready(token: i32, events: i32): void {
    if (token >= 0) {
      if (this.server.holds(token)) {
        if ((events & READABLE) !== 0) {
          this.server.readable(token)
        } else {
          this.server.writable(token)
        }
        this.drive(token)
      }
    } else if (token === TOKEN_LISTENER) {
      this.acceptAll()
    } else if (token <= TOKEN_BCRYPT && token > TOKEN_POOL) {
      const k: i32 = TOKEN_BCRYPT - token
      if (k < toI32(this.bcrypts.length)) {
        this.bcryptReady(k, events)
      }
    } else {
      const n: i32 = TOKEN_POOL - token
      const p: i32 = n / POOL_TOKENS
      const s: i32 = n % POOL_TOKENS
      if (p >= 0 && p < 2 && s < this.pools[p].size) {
        this.pgReady(p, s, events)
      }
    }
  }

  acceptAll(): void {
    while (true) {
      const slot: i32 = this.server.accept()
      if (slot >= 0) {
        if (slot < toI32(this.slotGen.length)) {
          // `expire` closes a slot without telling the worker: a request it
          // left that is in neither a pool nor the bcrypt service is freed here.
          const old: i32 = this.slotReq[slot]
          if (
            old >= 0 &&
            old < toI32(this.reqs.length) &&
            !this.reqs[old].inPool &&
            !this.reqs[old].inBcrypt
          ) {
            this.release(this.reqs[old])
          }
          this.slotGen[slot] = this.slotGen[slot] + 1
          this.slotReq[slot] = -1
        }
        pollAdd(this.loop, this.server.fd(slot), H1_WANT_READ, slot)
      } else if (slot !== H1_POOL_FULL) {
        return
      }
    }
  }

  /** Runs `slot`'s events, then re-arms or closes it. */
  drive(slot: i32): void {
    let event: i32 = this.server.next(slot)
    while (event !== H1_NEED_MORE && event !== H1_ERROR) {
      if (event === H1_REQUEST) {
        this.onHead(slot)
      } else if (event === H1_BODY) {
        const r: i32 = this.slotReq[slot]
        if (r >= 0) {
          const conn: Http1Connection = this.server.connection(slot)
          this.reqs[r].addBody(conn.data, conn.dataStart, conn.dataLength)
        }
      } else if (event === H1_END) {
        const r: i32 = this.slotReq[slot]
        if (r >= 0) {
          this.onEnd(this.reqs[r])
        }
      }
      event = this.server.next(slot)
    }
    const wants: i32 = this.server.flush(slot)
    if ((wants & H1_DONE) !== 0) {
      this.closeSlot(slot)
      return
    }
    this.ackDelayAfter(slot)
    if (this.server.rearm(slot, wants)) {
      pollModify(this.loop, this.server.fd(slot), wants & (H1_WANT_READ | H1_WANT_WRITE), slot)
    }
  }

  /**
   * After an answer on a kept-alive connection, its socket goes back to
   * delayed ACKs, so the client's next request is acknowledged by its answer
   * rather than by an ACK of its own. A client that paused longer than the
   * retransmit timeout puts Linux in quick-ACK mode, which sends that empty
   * ACK at once, before the request is even read; every one lands on the CPU
   * that takes the network interrupts. Linux leaves delayed mode on its own,
   * so it is set again after every answer. An idea from the challenge's
   * zig-iouring-nick-potts submission (`ackdelay`).
   */
  ackDelayAfter(slot: i32): void {
    if (slot < 0 || slot >= toI32(this.slotAnswered.length) || !this.slotAnswered[slot]) {
      return
    }
    this.slotAnswered[slot] = false
    if (!this.ackDelay) {
      return
    }
    const rc: i32 = netSetOption(this.server.fd(slot), NET_TCP_QUICKACK, 0)
    if (rc === -22 || rc === -95) {
      console.log(`conduit: TCP_QUICKACK refused (${rc}); ACKs stay as the kernel sends them`)
      this.ackDelay = false
    }
  }

  closeSlot(slot: i32): void {
    this.server.close(slot)
    if (slot >= 0 && slot < toI32(this.slotReq.length)) {
      this.slotGen[slot] = this.slotGen[slot] + 1
      const r: i32 = this.slotReq[slot]
      this.slotReq[slot] = -1
      // A request still in a pool or the bcrypt service is freed when it comes back.
      if (r >= 0 && !this.reqs[r].inPool && !this.reqs[r].inBcrypt) {
        this.release(this.reqs[r])
      }
    }
  }

  take(slot: i32): ConduitReq {
    if (this.free.length === 0) {
      this.reqs.push(new ConduitReq(toI32(this.reqs.length)))
      this.free.push(toI32(this.reqs.length) - 1)
    }
    const r: ConduitReq = this.reqs[this.free[this.free.length - 1]]
    this.free.pop()
    r.restart(slot, slot >= 0 && slot < toI32(this.slotGen.length) ? this.slotGen[slot] : 0)
    return r
  }

  release(r: ConduitReq): void {
    if (r.slot >= 0 && r.slot < toI32(this.slotReq.length) && this.slotReq[r.slot] === r.index) {
      this.slotReq[r.slot] = -1
    }
    wipe(r.pw)
    if (r.bodyLen > 0 && (r.route === R_SIGNUP || r.route === R_LOGIN || r.route === R_USER_PUT)) {
      // A request answered before its body was parsed (a 401, a 422) still
      // holds the password in it.
      wipe(r.body)
    }
    r.slot = -1
    r.inPool = false
    r.inBcrypt = false
    this.free.push(r.index)
  }

  // ---- Answers ----------------------------------------------------------------------

  /**
   * Answers `r` with `buf[0, len)` as its JSON body (no body for 204), and
   * frees it. `later` is true when the answer comes from a pool or the bcrypt
   * service rather than from the slot's own events, so the slot is driven
   * after it: its next pipelined request may be waiting.
   */
  answer(r: ConduitReq, status: i32, buf: u8[], len: i32, later: boolean): void {
    const slot: i32 = r.slot
    const live: boolean =
      slot >= 0 &&
      slot < toI32(this.slotGen.length) &&
      this.server.holds(slot) &&
      this.slotGen[slot] === r.gen
    const coding: i32 = r.coding
    this.release(r)
    if (!live) {
      return
    }
    this.answered += 1
    const conn: Http1Connection = this.server.connection(slot)
    if (status === 204) {
      conn.respond(status, this.noNames, this.noNames, HTTP1_NO_BODY)
      conn.end()
    } else if (!this.answerGzipped(conn, status, buf, len, coding)) {
      conn.respond(status, this.jsonNames, this.jsonValues, len)
      conn.write(buf, 0, len)
      conn.end()
    }
    if (slot < toI32(this.slotAnswered.length)) {
      this.slotAnswered[slot] = true
    }
    if (later) {
      this.drive(slot)
    }
  }

  /**
   * Answers with `buf[0, len)` through `HttpCompressor`, which sends it gzipped
   * only when that pays (`WorkerConfig.gzip`); false when it was left unanswered.
   * Sending gzip only when it saves a TCP segment is an idea from the challenge's
   * zig-iouring-nick-potts submission; the policy is Nish's own since 0.28.0.
   */
  answerGzipped(conn: Http1Connection, status: i32, buf: u8[], len: i32, coding: i32): boolean {
    const enc: HttpCompressor | null = this.gzip
    if (enc === null || len < enc.minLength) {
      return false
    }
    return conn.respondEncoded(status, this.jsonNames, this.jsonValues, buf, 0, len, enc, coding) === 0
  }

  /** Answers `r` with what `w` wrote into `buf`, or 500 when it did not fit: a cut JSON text is never sent. */
  answerWritten(r: ConduitReq, status: i32, w: JsonWriter, buf: u8[]): void {
    if (w.failed !== 0) {
      this.fail(r, 500, "the response is too large", true)
      return
    }
    this.answer(r, status, buf, w.end, true)
  }

  /** Answers `r` with `{"errors":{"body":[message]}}`. */
  fail(r: ConduitReq, status: i32, message: string, later: boolean): void {
    const w: JsonWriter = this.plain
    w.reset(this.plainBuf, 0)
    w.beginObject()
    w.key("errors")
    w.beginObject()
    w.key("body")
    w.beginArray()
    w.string(message)
    w.endArray()
    w.endObject()
    w.endObject()
    this.answer(r, status, this.plainBuf, w.end, later)
  }

  // ---- A request's head and body ---------------------------------------------------

  /** A request head arrived on `slot`: route it and read its token. */
  onHead(slot: i32): void {
    const r: ConduitReq = this.take(slot)
    if (slot >= 0 && slot < toI32(this.slotReq.length)) {
      this.slotReq[slot] = r.index
    }
    const conn: Http1Connection = this.server.connection(slot)
    const p: Http1Parser = conn.parser
    // Read now: a request waiting on Postgres leaves its head to the next one's rest.
    r.coding = this.gzip !== null ? conn.acceptEncoding() : HTTP_CODING_IDENTITY
    this.route(r, p)
    if (r.status !== 0 || r.route === R_TAGS || r.route === R_SIGNUP || r.route === R_LOGIN) {
      return
    }
    // The token: absent is the anonymous viewer, present and bad is 401.
    const h: i32 = p.headerIndex("authorization")
    if (h < 0) {
      if (this.authRequired(r.route)) {
        r.status = 401
      }
      return
    }
    const start: i32 = p.spans[4 * h + 2]
    const end: i32 = p.spans[4 * h + 3]
    if (end - start <= 6 || !bytesAre(p.head, start, start + 6, "Token ")) {
      r.status = 401
      return
    }
    const now: i64 = toI64(Date.now()) / 1000
    if (!this.jwt.verify(p.head, start + 6, end - start - 6, now)) {
      r.status = 401
      return
    }
    r.viewer = this.jwt.sub
    if (r.route === R_USER_GET || r.route === R_USER_PUT) {
      r.setField(F_TOKEN, p.head, start + 6, end - start - 6)
    }
  }

  authRequired(route: i32): boolean {
    return route !== R_PROFILE && route !== R_LIST && route !== R_ARTICLE_GET && route !== R_COMMENTS
  }

  /** Sets `r.route` and its path and query parameters from the request line, or `r.status` when it names nothing. */
  route(r: ConduitReq, p: Http1Parser): void {
    const b: u8[] = p.head
    const start: i32 = p.targetStart
    const end: i32 = p.targetEnd
    let pathEnd: i32 = start
    while (pathEnd < end && toI32(b[pathEnd]) !== 63) {
      pathEnd++
    }
    if (!(pathEnd - start >= 5 && bytesAre(b, start, start + 5, "/api/"))) {
      r.status = 404
      return
    }
    // Up to four segments after /api/.
    const segStart: i32[] = [0, 0, 0, 0]
    const segEnd: i32[] = [0, 0, 0, 0]
    let segs: i32 = 0
    let at: i32 = start + 5
    while (at <= pathEnd && segs < 5) {
      let e: i32 = at
      while (e < pathEnd && toI32(b[e]) !== 47) {
        e++
      }
      if (segs < 4) {
        segStart[segs] = at
        segEnd[segs] = e
      }
      segs++
      at = e + 1
    }
    if (segs > 4 || segEnd[segs - 1] === segStart[segs - 1]) {
      r.status = 404
      return
    }
    const get: boolean = p.methodIs("GET")
    const post: boolean = p.methodIs("POST")
    const put: boolean = p.methodIs("PUT")
    const del: boolean = p.methodIs("DELETE")
    const s0s: i32 = segStart[0]
    const s0e: i32 = segEnd[0]
    let route: i32 = R_NONE
    if (bytesAre(b, s0s, s0e, "tags")) {
      if (segs === 1 && get) {
        route = R_TAGS
      }
    } else if (bytesAre(b, s0s, s0e, "users")) {
      if (segs === 1 && post) {
        route = R_SIGNUP
      } else if (segs === 2 && post && bytesAre(b, segStart[1], segEnd[1], "login")) {
        route = R_LOGIN
      }
    } else if (bytesAre(b, s0s, s0e, "user")) {
      if (segs === 1) {
        if (get) {
          route = R_USER_GET
        } else if (put) {
          route = R_USER_PUT
        } else {
          route = R_NONE
        }
      }
    } else if (bytesAre(b, s0s, s0e, "profiles")) {
      if (segs === 2 && get) {
        route = R_PROFILE
      } else if (segs === 3 && bytesAre(b, segStart[2], segEnd[2], "follow")) {
        if (post) {
          route = R_FOLLOW
        } else if (del) {
          route = R_UNFOLLOW
        } else {
          route = R_NONE
        }
      }
      if (route !== R_NONE) {
        this.decodeInto(r, F_PATH, b, segStart[1], segEnd[1], false)
      }
    } else if (bytesAre(b, s0s, s0e, "articles")) {
      if (segs === 1) {
        if (get) {
          route = R_LIST
        } else if (post) {
          route = R_ARTICLE_CREATE
        } else {
          route = R_NONE
        }
      } else if (segs === 2 && get && bytesAre(b, segStart[1], segEnd[1], "feed")) {
        route = R_FEED
      } else if (segs === 2) {
        if (get) {
          route = R_ARTICLE_GET
        } else if (put) {
          route = R_ARTICLE_PUT
        } else if (del) {
          route = R_ARTICLE_DELETE
        } else {
          route = R_NONE
        }
      } else if (segs === 3 && bytesAre(b, segStart[2], segEnd[2], "favorite")) {
        if (post) {
          route = R_FAVORITE
        } else if (del) {
          route = R_UNFAVORITE
        } else {
          route = R_NONE
        }
      } else if (segs === 3 && bytesAre(b, segStart[2], segEnd[2], "comments")) {
        if (get) {
          route = R_COMMENTS
        } else if (post) {
          route = R_COMMENT_CREATE
        } else {
          route = R_NONE
        }
      } else if (segs === 4 && del && bytesAre(b, segStart[2], segEnd[2], "comments")) {
        const id: i64 = decimalOf(b, segStart[3], segEnd[3])
        if (id > 0) {
          route = R_COMMENT_DELETE
          r.commentId = id
        }
      }
      if (route !== R_NONE && route !== R_LIST && route !== R_ARTICLE_CREATE && route !== R_FEED) {
        this.decodeInto(r, F_PATH, b, segStart[1], segEnd[1], false)
      }
    }
    if (route === R_NONE) {
      r.status = 404
      return
    }
    r.route = route
    if ((route === R_LIST || route === R_FEED) && pathEnd < end) {
      this.query(r, b, pathEnd + 1, end)
    }
  }

  /** Percent-decodes `b[start, end)` into field `f`; `plus` reads `+` as a space, as a query does. */
  decodeInto(r: ConduitReq, f: i32, b: u8[], start: i32, end: i32, plus: boolean): void {
    r.room(end - start)
    const out: u8[] = r.text
    let o: i32 = r.textEnd
    let k: i32 = start
    while (k < end) {
      const c: i32 = toI32(b[k])
      if (c === 37 && k + 2 < end) {
        const hi: i32 = hexValue(toI32(b[k + 1]))
        const lo: i32 = hexValue(toI32(b[k + 2]))
        if (hi >= 0 && lo >= 0) {
          out[o] = toU8(hi * 16 + lo)
          o++
          k += 3
          continue
        }
      }
      out[o] = toU8(plus && c === 43 ? 32 : c)
      o++
      k++
    }
    r.fStart[f] = r.textEnd
    r.fLen[f] = o - r.textEnd
    r.textEnd = o
  }

  /** Reads `limit`, `offset` and the first non-empty filter from the query `b[start, end)`; 422 for a bad number. */
  query(r: ConduitReq, b: u8[], start: i32, end: i32): void {
    let at: i32 = start
    let sawLimit: boolean = false
    let sawOffset: boolean = false
    const filterKind: i32[] = [0, 0, 0, 0]
    const filterStart: i32[] = [0, 0, 0, 0]
    const filterLen: i32[] = [-1, -1, -1, -1]
    while (at < end) {
      let e: i32 = at
      while (e < end && toI32(b[e]) !== 38) {
        e++
      }
      let eq: i32 = at
      while (eq < e && toI32(b[eq]) !== 61) {
        eq++
      }
      const vs: i32 = eq < e ? eq + 1 : e
      if (bytesAre(b, at, eq, "limit") && !sawLimit) {
        sawLimit = true
        this.decodeInto(r, F_FILTER, b, vs, e, true)
        const v: i64 = decimalOf(r.text, r.fStart[F_FILTER], r.fStart[F_FILTER] + r.fLen[F_FILTER])
        if (v < 1 || v > 100) {
          r.status = 422
        }
        r.limit = v
      } else if (bytesAre(b, at, eq, "offset") && !sawOffset) {
        sawOffset = true
        this.decodeInto(r, F_FILTER, b, vs, e, true)
        const v: i64 = decimalOf(r.text, r.fStart[F_FILTER], r.fStart[F_FILTER] + r.fLen[F_FILTER])
        if (v < 0 || v > 2147483647) {
          r.status = 422
        }
        r.offset = v
      } else if (r.route === R_LIST) {
        let kind: i32 = 0
        if (bytesAre(b, at, eq, "tag")) {
          kind = FILTER_TAG
        } else if (bytesAre(b, at, eq, "author")) {
          kind = FILTER_AUTHOR
        } else if (bytesAre(b, at, eq, "favorited")) {
          kind = FILTER_FAVORITED
        }
        if (kind > 0 && filterLen[kind] < 0 && e > vs) {
          this.decodeInto(r, F_FILTER, b, vs, e, true)
          filterStart[kind] = r.fStart[F_FILTER]
          filterLen[kind] = r.fLen[F_FILTER]
          filterKind[kind] = 1
        }
      }
      at = e + 1
    }
    r.fLen[F_FILTER] = -1
    for (let kind: i32 = FILTER_TAG; kind <= FILTER_FAVORITED; kind++) {
      if (filterKind[kind] === 1 && filterLen[kind] > 0 && r.filter === FILTER_NONE) {
        r.filter = kind
        r.fStart[F_FILTER] = filterStart[kind]
        r.fLen[F_FILTER] = filterLen[kind]
      }
    }
  }

  /** The body ended: check it and start the request, or answer what is wrong. */
  onEnd(r: ConduitReq): void {
    if (r.status !== 0) {
      let message: string = "not found"
      if (r.status === 401) {
        message = "unauthorized"
      } else if (r.status === 422) {
        message = "invalid query"
      }
      this.fail(r, r.status, message, false)
      return
    }
    const route: i32 = r.route
    if (route === R_SIGNUP || route === R_LOGIN || route === R_USER_PUT) {
      let fields: i32 = FIELDS_USER
      if (route === R_SIGNUP) {
        fields = FIELDS_SIGNUP
      } else if (route === R_LOGIN) {
        fields = FIELDS_LOGIN
      }
      const ok: boolean = this.parseBody(r, "user", fields)
      // The raw body held the password; the parsed copy is in `pw`.
      wipe(r.body)
      r.bodyLen = 0
      if (!ok || !this.userBodyValid(r)) {
        wipe(r.pw)
        this.fail(r, 422, "invalid user", false)
        return
      }
    } else if (route === R_ARTICLE_CREATE || route === R_ARTICLE_PUT) {
      if (!this.parseBody(r, "article", FIELDS_ARTICLE) || !this.articleBodyValid(r)) {
        this.fail(r, 422, "invalid article", false)
        return
      }
    } else if (route === R_COMMENT_CREATE) {
      if (!this.parseBody(r, "comment", FIELDS_COMMENT) || r.fLen[F_BODY] <= 0) {
        this.fail(r, 422, "invalid comment", false)
        return
      }
    }
    if (route === R_LOGIN && r.pwLen > BCRYPT_MAX_PASSWORD) {
      wipe(r.pw)
      this.fail(r, 401, "invalid credentials", false)
      return
    }
    if (route === R_SIGNUP || (route === R_USER_PUT && r.pwLen >= 0)) {
      this.toBcrypt(r, BCRYPT_OP_HASH, false)
      return
    }
    this.submit(r, false)
  }

  userBodyValid(r: ConduitReq): boolean {
    if (r.route === R_SIGNUP) {
      return r.fLen[F_USERNAME] > 0 && r.fLen[F_EMAIL] > 0 && r.pwLen > 0 && r.pwLen <= BCRYPT_MAX_PASSWORD
    }
    if (r.route === R_LOGIN) {
      return r.fLen[F_EMAIL] > 0 && r.pwLen > 0
    }
    // PUT: a field given must not be empty, but bio and image may be.
    return (
      r.fLen[F_USERNAME] !== 0 && r.fLen[F_EMAIL] !== 0 && r.pwLen !== 0 && r.pwLen <= BCRYPT_MAX_PASSWORD
    )
  }

  articleBodyValid(r: ConduitReq): boolean {
    if (r.badTags) {
      return false
    }
    if (r.route === R_ARTICLE_CREATE) {
      return r.fLen[F_TITLE] > 0 && r.fLen[F_DESCRIPTION] > 0 && r.fLen[F_BODY] > 0
    }
    return r.fLen[F_TITLE] !== 0 && r.fLen[F_DESCRIPTION] !== 0 && r.fLen[F_BODY] !== 0
  }

  /** The field a key names for a route that reads `fields`, or -1 to skip it. */
  fieldOf(t: JsonTokenizer, fields: i32): i32 {
    if ((fields & (1 << F_USERNAME)) !== 0 && t.keyEquals("username")) {
      return F_USERNAME
    }
    if ((fields & (1 << F_EMAIL)) !== 0 && t.keyEquals("email")) {
      return F_EMAIL
    }
    if ((fields & BIT_PASSWORD) !== 0 && t.keyEquals("password")) {
      return F_PASSWORD
    }
    if ((fields & (1 << F_BIO)) !== 0 && t.keyEquals("bio")) {
      return F_BIO
    }
    if ((fields & (1 << F_IMAGE)) !== 0 && t.keyEquals("image")) {
      return F_IMAGE
    }
    if ((fields & (1 << F_TITLE)) !== 0 && t.keyEquals("title")) {
      return F_TITLE
    }
    if ((fields & (1 << F_DESCRIPTION)) !== 0 && t.keyEquals("description")) {
      return F_DESCRIPTION
    }
    if ((fields & (1 << F_BODY)) !== 0 && t.keyEquals("body")) {
      return F_BODY
    }
    if ((fields & BIT_TAGLIST) !== 0 && t.keyEquals("tagList")) {
      return F_TAGLIST
    }
    return -1
  }

  /**
   * Reads `{"<wrapper>": {...}}` from the body: each field the route reads
   * is a string or null, a `tagList` an array of non-empty strings or null;
   * anything else in the body is skipped. False for malformed JSON, a
   * missing wrapper, or a field of the wrong type.
   */
  parseBody(r: ConduitReq, wrapper: string, fields: i32): boolean {
    const t: JsonTokenizer = this.tokenizer
    t.reset(r.body, 0, r.bodyLen)
    if (t.next() !== JSON_TOK_OBJECT_BEGIN) {
      return false
    }
    let found: boolean = false
    let k: i32 = t.next()
    while (k === JSON_TOK_KEY) {
      if (t.keyEquals(wrapper)) {
        if (t.next() !== JSON_TOK_OBJECT_BEGIN) {
          return false
        }
        found = true
        let k2: i32 = t.next()
        while (k2 === JSON_TOK_KEY) {
          const f: i32 = this.fieldOf(t, fields)
          if (f === F_TAGLIST) {
            if (!this.parseTags(r, t)) {
              return false
            }
          } else if (f >= 0) {
            const v: i32 = t.next()
            if (v === JSON_TOK_STRING) {
              this.store(r, f, t)
            } else if (v === JSON_TOK_NULL) {
              if (f === F_PASSWORD) {
                r.pwLen = -1
              } else {
                r.fLen[f] = -1
              }
            } else {
              return false
            }
          } else if (t.skipValue() < 0) {
            return false
          }
          k2 = t.next()
        }
        if (k2 !== JSON_TOK_OBJECT_END) {
          return false
        }
      } else if (t.skipValue() < 0) {
        return false
      }
      k = t.next()
    }
    return k === JSON_TOK_OBJECT_END && t.next() === JSON_TOK_END && t.failed === 0 && found
  }

  /** Stores the current string as field `f`. */
  store(r: ConduitReq, f: i32, t: JsonTokenizer): void {
    const len: i32 = t.stringLength()
    if (f === F_PASSWORD) {
      if (len > BCRYPT_MAX_PASSWORD) {
        r.pwLen = BCRYPT_MAX_PASSWORD + 1
      } else {
        r.pwLen = t.stringInto(r.pw, 0)
      }
      return
    }
    r.room(len)
    const n: i32 = t.stringInto(r.text, r.textEnd)
    r.fStart[f] = r.textEnd
    r.fLen[f] = n < 0 ? 0 : n
    r.textEnd += n < 0 ? 0 : n
  }

  /** Reads a `tagList` into field `F_TAGS` as a `text[]` literal; false for a value that is not one. */
  parseTags(r: ConduitReq, t: JsonTokenizer): boolean {
    const v: i32 = t.next()
    if (v === JSON_TOK_NULL) {
      return true
    }
    if (v !== JSON_TOK_ARRAY_BEGIN) {
      return false
    }
    const start: i32 = r.textEnd
    r.room(1)
    r.text[r.textEnd] = toU8(123)
    r.textEnd += 1
    let n: i32 = 0
    let e: i32 = t.next()
    while (e === JSON_TOK_STRING) {
      const len: i32 = t.stringLength()
      if (len <= 0) {
        r.badTags = true
        return false
      }
      // Decoded into the scratch, then quoted with `"` and `\` escaped.
      if (len > toI32(this.scratch.length)) {
        return false
      }
      t.stringInto(this.scratch, 0)
      r.room(2 * len + 4)
      if (n > 0) {
        r.text[r.textEnd] = toU8(44)
        r.textEnd += 1
      }
      r.text[r.textEnd] = toU8(34)
      r.textEnd += 1
      for (let k: i32 = 0; k < len; k++) {
        const c: i32 = toI32(this.scratch[k])
        if (c === 34 || c === 92) {
          r.text[r.textEnd] = toU8(92)
          r.textEnd += 1
        }
        r.text[r.textEnd] = toU8(c)
        r.textEnd += 1
      }
      r.text[r.textEnd] = toU8(34)
      r.textEnd += 1
      n++
      e = t.next()
    }
    if (e !== JSON_TOK_ARRAY_END) {
      r.badTags = true
      return false
    }
    r.room(1)
    r.text[r.textEnd] = toU8(125)
    r.textEnd += 1
    r.tags = n
    r.fStart[F_TAGS] = start
    r.fLen[F_TAGS] = r.textEnd - start
    return true
  }

  // ---- Pools ----------------------------------------------------------------------

  /** The pool a request's current phase runs on. */
  poolOf(r: ConduitReq): i32 {
    const route: i32 = r.route
    if (route === R_ARTICLE_PUT) {
      return r.phase === 0 ? POOL_READ : POOL_WRITE
    }
    if (
      route === R_SIGNUP ||
      route === R_USER_PUT ||
      route === R_FOLLOW ||
      route === R_UNFOLLOW ||
      route === R_ARTICLE_CREATE ||
      route === R_ARTICLE_DELETE ||
      ((route === R_FAVORITE || route === R_UNFAVORITE) && r.phase === 0) ||
      route === R_COMMENT_CREATE ||
      route === R_COMMENT_DELETE
    ) {
      return POOL_WRITE
    }
    return POOL_READ
  }

  /** Queues `r`'s next group on its pool. */
  submit(r: ConduitReq, later: boolean): void {
    const p: i32 = this.poolOf(r)
    if (p === POOL_WRITE && !r.solo) {
      // Writes wait for the next batch: `batchWrites` sends them.
      this.wait(r, p)
      if (this.writeCount === QUEUE) {
        r.inPool = false
        this.fail(r, 503, "busy", later)
        return
      }
      this.writeRing[(this.writeHead + this.writeCount) % QUEUE] = r.index
      this.writeCount += 1
      return
    }
    if (p === POOL_READ && !r.solo && this.planKind(r) >= 0) {
      // The tag list, lists, feeds, articles and comments wait for the next read plan: `startPlans` takes them.
      this.wait(r, p)
      if (this.planCount === QUEUE) {
        r.inPool = false
        this.fail(r, 503, "busy", later)
        return
      }
      const at: i32 = (this.planHead + this.planCount) % QUEUE
      this.planRing[at] = r.index
      const now: i64 = monotonicNanos()
      this.planAt[at] = now
      this.planCount += 1
      this.arrived(now)
      return
    }
    const ticket: i32 = this.pools[p].request()
    if (ticket === PG_POOL_FULL) {
      this.fail(r, 503, "busy", later)
      return
    }
    this.tickets[p][ticket % TICKET_RING] = r.index
    r.pool = p
    r.ticket = ticket
    r.inPool = true
    r.stmt = 0
    r.found = false
    r.pgError = 0
  }

  /** The read plan kind `r` is (`K_`), or -1 for a request read on its own. */
  planKind(r: ConduitReq): i32 {
    let kind: i32 = -1
    let f: i32 = F_FILTER
    if (r.route === R_LIST) {
      if (r.filter === FILTER_NONE) {
        return K_GLOBAL
      }
      kind = r.filter === FILTER_TAG ? K_TAG : r.filter === FILTER_AUTHOR ? K_AUTHOR : K_FAVORITED
    } else if (r.route === R_FEED) {
      return K_FEED
    } else if (r.route === R_TAGS) {
      return K_TAGS
    } else if (r.route === R_ARTICLE_GET || r.route === R_COMMENTS) {
      kind = r.route === R_ARTICLE_GET ? K_ARTICLE : K_COMMENTS
      f = F_PATH
    } else if ((r.route === R_FAVORITE || r.route === R_UNFAVORITE) && r.phase === 1) {
      // A toggle's article, read once its write has committed.
      kind = K_ARTICLE
      f = F_PATH
    } else if (r.route === R_PROFILE) {
      kind = K_PROFILE
      f = F_PATH
    } else {
      return -1
    }
    // A key Postgres would refuse, or a long one, is read alone.
    const start: i32 = r.fStart[f]
    const len: i32 = r.fLen[f]
    if (len < 0 || len > PLAN_KEY_MAX || !isText(r.text, start, start + len)) {
      return -1
    }
    return kind
  }

  /**
   * Starts a read plan in each free one while reads wait: it takes them,
   * up to its caps, and asks the read pool for its group A.
   */
  startPlans(): void {
    const pool: PgPool = this.pools[POOL_READ]
    for (let p: i32 = 0; p < toI32(this.plans.length) && this.planCount > 0; p++) {
      if (this.planState[p] !== PLAN_FREE) {
        continue
      }
      if (this.planWaitLeft() > 0) {
        return
      }
      const ticket: i32 = pool.request()
      if (ticket === PG_POOL_FULL) {
        return
      }
      const plan: ReadPlan = this.plans[p]
      plan.reset()
      while (this.planCount > 0) {
        const r: ConduitReq = this.reqs[this.planRing[this.planHead]]
        const kind: i32 = this.planKind(r)
        const f: i32 = kind === K_ARTICLE || kind === K_COMMENTS || kind === K_PROFILE ? F_PATH : F_FILTER
        if (!plan.add(r.index, kind, r.viewer, r.limit, r.offset, r.text, r.fStart[f], r.fLen[f])) {
          break
        }
        this.planHead = (this.planHead + 1) % QUEUE
        this.planCount -= 1
      }
      const at: i32 = ticket % TICKET_RING
      this.tickets[POOL_READ][at] = -1
      this.ticketPlan[at] = p
      this.planState[p] = PLAN_A
    }
  }

  /**
   * How long, in ns, the reads waiting should wait still for a plan of their
   * own: 0 once `planMin` wait or the oldest has waited `planWait`. With
   * `planClock` off the window gathers reads only while a plan runs, and an
   * idle worker starts one at once.
   */
  planWaitLeft(): i64 {
    if (this.planCount === 0 || this.planCount >= this.planMin) {
      return 0
    }
    // An adaptive clock gathers only while enough reads come to fill a plan
    // worth the wait; a quiet worker (or one quiet for 50 ms) starts at once.
    let busy: boolean =
      this.planClock === 1 ||
      (this.planClock === 2 &&
        this.perWindow >= this.planLight &&
        monotonicNanos() - this.rateAt < toI64(2) * this.measureSpan())
    for (let p: i32 = 0; p < toI32(this.planState.length); p++) {
      busy = busy || this.planState[p] !== PLAN_FREE
    }
    if (!busy) {
      return 0
    }
    const left: i64 = this.planAt[this.planHead] + this.planWait - monotonicNanos()
    return left > 0 ? left : 0
  }

  /**
   * Counts a read that came for a plan, and every 50 ms (or a window, when
   * longer) measures how many come a window: what an adaptive clock
   * (`planClock` 2) gathers by.
   */
  arrived(now: i64): void {
    this.arrivals += 1
    const span: i64 = now - this.rateAt
    if (span >= this.measureSpan()) {
      this.perWindow = span > 0 ? (this.arrivals * this.planWait) / span : 0
      this.arrivals = 0
      this.rateAt = now
    }
  }

  /** How long the arrival rate is measured over, in ns: 50 ms, or a window when longer. */
  measureSpan(): i64 {
    const floor: i64 = 50000000
    return this.planWait > floor ? this.planWait : floor
  }

  /** Plan `p`'s group ended: after group A, asks for group B when it has anything to read, else answers. */
  planGroupDone(p: i32): void {
    const plan: ReadPlan = this.plans[p]
    if (this.planState[p] === PLAN_A) {
      if (plan.failed) {
        plan.abortA()
        this.planFinish(p, false)
        return
      }
      if (plan.planB()) {
        if (plan.metas > 0) {
          if (this.countRuns[this.countOpen].join(p, plan)) {
            this.planState[p] = PLAN_COUNT
            return
          }
          plan.failed = true
        } else if (this.planAskB(p)) {
          return
        }
      }
    }
    this.planFinish(p, false)
  }

  /** Asks the read pool for plan `p`'s group B; false, with the plan failed, when the pool is full. */
  planAskB(p: i32): boolean {
    const ticket: i32 = this.pools[POOL_READ].request()
    if (ticket === PG_POOL_FULL) {
      this.plans[p].failed = true
      return false
    }
    const at: i32 = ticket % TICKET_RING
    this.tickets[POOL_READ][at] = -1
    this.ticketPlan[at] = p
    this.planState[p] = PLAN_B
    return true
  }

  /** Asks the read pool for the next count run, when plans wait for one and none is running. */
  startCounts(): void {
    if (this.countBusy || this.countRuns[this.countOpen].plans.length === 0) {
      return
    }
    const ticket: i32 = this.pools[POOL_READ].request()
    if (ticket === PG_POOL_FULL) {
      return
    }
    const at: i32 = ticket % TICKET_RING
    this.tickets[POOL_READ][at] = -1
    this.ticketPlan[at] = toI32(this.plans.length)
    this.countBusy = true
  }

  /** The running count run ended: each of its plans goes on to group B, or alone, or fails with the connection. */
  countsDone(failed: boolean, lost: boolean): void {
    const run: CountRun = this.countRuns[1 - this.countOpen]
    this.countBusy = false
    for (const p of run.plans) {
      if (lost) {
        this.planFinish(p, true)
      } else {
        const plan: ReadPlan = this.plans[p]
        plan.failed = plan.failed || failed || run.failed
        plan.takeCounts(run)
        if (plan.failed || !this.planAskB(p)) {
          this.planFinish(p, false)
        }
      }
    }
    run.reset()
  }

  /**
   * Answers every request of plan `p` and frees it: from the plan's rows; or,
   * when the plan failed or could not answer one, by sending it again alone,
   * where it answers its own error; or 500 when the connection was lost.
   */
  planFinish(p: i32, lost: boolean): void {
    const plan: ReadPlan = this.plans[p]
    for (let i: i32 = 0; i < plan.count; i++) {
      const r: ConduitReq = this.reqs[plan.tags[i]]
      r.inPool = false
      if (lost) {
        this.fail(r, 500, "the database connection was lost", true)
        continue
      }
      const status: i32 = plan.failed ? PLAN_ALONE : plan.render(i)
      if (status === PLAN_ALONE) {
        r.solo = true
        this.submit(r, true)
      } else if (status === 404) {
        this.fail(r, 404, r.route === R_COMMENTS ? "article not found" : "not found", true)
      } else {
        this.answer(r, status, plan.out, plan.outEnd, true)
      }
    }
    this.planState[p] = PLAN_FREE
  }

  /** One event of a plan's group. */
  planEvent(ticket: i32, conn: PgConnection, event: i32): void {
    const at: i32 = ticket % TICKET_RING
    const p: i32 = this.ticketPlan[at]
    if (p === toI32(this.plans.length)) {
      this.countEvent(at, conn, event)
      return
    }
    const plan: ReadPlan = this.plans[p]
    if (event === PG_LOST) {
      this.ticketPlan[at] = -1
      plan.abortA()
      this.planFinish(p, true)
    } else if (event === PG_GROUP_DONE) {
      this.ticketPlan[at] = -1
      if (conn.groupFailed) {
        plan.failed = true
      }
      this.planGroupDone(p)
    } else if (this.planState[p] === PLAN_A) {
      plan.eventA(conn, event)
    } else {
      plan.eventB(conn, event)
    }
  }

  /** One event of the running count run. */
  countEvent(at: i32, conn: PgConnection, event: i32): void {
    if (event === PG_LOST) {
      this.ticketPlan[at] = -1
      this.countsDone(true, true)
    } else if (event === PG_GROUP_DONE) {
      this.ticketPlan[at] = -1
      this.countsDone(conn.groupFailed, false)
    } else {
      this.countRuns[1 - this.countOpen].event(conn, event)
    }
  }

  /** Marks `r` as waiting in one of the worker's rings for pool `p`, with no ticket yet. */
  wait(r: ConduitReq, p: i32): void {
    r.pool = p
    r.ticket = -1
    r.inPool = true
    r.stmt = 0
    r.found = false
    r.pgError = 0
    r.batchNext = -1
  }

  /** Hands waiting requests to connections, makes the connections wanted, and sends what they queued. */
  pump(): void {
    this.batchWrites()
    this.startPlans()
    this.startCounts()
    for (let p: i32 = 0; p < 2; p++) {
      const pool: PgPool = this.pools[p]
      let s: i32 = pool.dispatch()
      while (s >= 0) {
        const conn: PgConnection = pool.connection(s)
        const at: i32 = pool.ticket % TICKET_RING
        if (p === POOL_READ && this.ticketPlan[at] >= 0) {
          // A read plan's group: its statements over the plan's keys.
          const pi: i32 = this.ticketPlan[at]
          if (pi === toI32(this.plans.length)) {
            // The count run: it takes every plan waiting now, and the next plans open the other.
            const run: CountRun = this.countRuns[this.countOpen]
            this.countOpen = 1 - this.countOpen
            const counted: boolean = run.bind(conn)
            if (!counted) {
              conn.bindCancel()
            }
            run.failed = !counted
            if (!pool.send()) {
              this.ticketPlan[at] = -1
              this.countsDone(true, false)
            }
            s = pool.dispatch()
            continue
          }
          const plan: ReadPlan = this.plans[pi]
          const bound: boolean = this.planState[pi] === PLAN_A ? plan.bindA(conn) : plan.bindB(conn)
          if (!bound) {
            // The statements bound still run; the plan's requests go alone once they have.
            plan.failed = true
            conn.bindCancel()
          }
          if (!pool.send()) {
            // Nothing was written: no event will come for it.
            this.ticketPlan[at] = -1
            plan.failed = true
            this.planGroupDone(pi)
          }
          s = pool.dispatch()
          continue
        }
        const r: i32 = this.tickets[p][at]
        const built: boolean = r >= 0 && r < toI32(this.reqs.length) && this.bindAll(this.reqs[r], conn)
        if (!pool.send() && conn.bindEnd()) {
          // A bind refused part way left the group open with the bind in it,
          // which no Sync can end, and the pool would wait on it for good.
          // Ended with the parameters it has, the bind is one Postgres
          // refuses: the group fails, its implicit transaction rolls back
          // whatever else it held, and the Sync ends it.
          pool.send()
        }
        const leaderDeferred: boolean =
          this.deferred.length > 0 && this.deferred[this.deferred.length - 1] === r
        if (leaderDeferred) {
          // Nothing of the group was bound: the pool dropped it, or sends only
          // the statements it prepared, whose events now answer no request.
          if (!this.reqs[r].solo) {
            this.writeBatches -= 1
          }
        } else if (!built) {
          // A bind was refused for a reason other than room: the request, and
          // every write batched with it, answers 500, and none is sent again.
          if (r >= 0 && r < toI32(this.reqs.length) && this.reqs[r].inPool) {
            if (p === POOL_WRITE && !this.reqs[r].solo) {
              this.writeBatches -= 1
            }
            let k: i32 = r
            while (k >= 0) {
              const req: ConduitReq = this.reqs[k]
              k = req.batchNext
              req.batchNext = -1
              req.inPool = false
              this.fail(req, 500, "statement not sent", true)
            }
          }
        }
        s = pool.dispatch()
      }
      s = pool.wanted()
      while (s >= 0 && s < pool.size) {
        const socket: PgSocket = this.sockets[p][s]
        const nonce = new Array<u8>(18)
        crypto.getRandomValues(nonce)
        pool.connect(s, nonce)
        socket.fd = tcpConnect(this.pgAddress)
        socket.connected = false
        socket.armed = H1_WANT_WRITE
        if (
          socket.fd < 0 ||
          pollAdd(this.loop, socket.fd, H1_WANT_WRITE, TOKEN_POOL - (p * POOL_TOKENS + s)) < 0
        ) {
          pool.connection(s).closed()
          this.pgEvents(p, s)
        }
        s = pool.wanted()
      }
      for (let k: i32 = 0; k < pool.size; k++) {
        const socket: PgSocket = this.sockets[p][k]
        if (socket.fd >= 0 && socket.connected) {
          const conn: PgConnection = pool.connection(k)
          if (!this.pgFlush(conn, socket.fd)) {
            conn.closed()
            this.pgEvents(p, k)
          } else if (socket.fd >= 0) {
            // Each pollModify is an epoll_ctl; a busy connection asks for the
            // same interest turn after turn, so it is re-armed only on a change.
            const wants: i32 =
              conn.outputEnd() > conn.outputStart() ? H1_WANT_READ | H1_WANT_WRITE : H1_WANT_READ
            if (wants !== socket.armed) {
              socket.armed = wants
              pollModify(this.loop, socket.fd, wants, TOKEN_POOL - (p * POOL_TOKENS + k))
            }
          }
        }
      }
    }
    // The writes `bindAll` held back go again once what waited has been sent.
    while (this.deferred.length > 0) {
      let k: i32 = this.deferred[this.deferred.length - 1]
      this.deferred.pop()
      while (k >= 0) {
        const m: ConduitReq = this.reqs[k]
        k = m.batchNext
        this.submit(m, true)
      }
    }
  }

  /**
   * Group commit: while fewer batches are in flight than there are write
   * connections, the writes waiting (up to `WRITE_BATCH`) become one request
   * of the write pool, one group, so one implicit transaction and one commit.
   * Each write's answer waits for the group's ReadyForQuery. Nothing waits on
   * a timer: under load the writes that come while a batch is in flight make
   * the next one, and an idle server sends a write at once.
   */
  batchWrites(): void {
    const pool: PgPool = this.pools[POOL_WRITE]
    while (this.writeCount > 0 && this.writeBatches < pool.size) {
      const ticket: i32 = pool.request()
      if (ticket === PG_POOL_FULL) {
        return
      }
      let take: i32 = 0
      let bytes: i32 = 0
      while (take < this.writeCount && take < WRITE_BATCH) {
        const cost: i32 = writeCost(this.reqs[this.writeRing[(this.writeHead + take) % QUEUE]])
        if (take > 0 && bytes + cost > WRITE_BATCH_BYTES) {
          break
        }
        bytes += cost
        take += 1
      }
      for (let k: i32 = 0; k < take; k++) {
        const r: ConduitReq = this.reqs[this.writeRing[(this.writeHead + k) % QUEUE]]
        r.ticket = ticket
        r.batchNext = k + 1 < take ? this.writeRing[(this.writeHead + k + 1) % QUEUE] : -1
      }
      this.tickets[POOL_WRITE][ticket % TICKET_RING] = this.writeRing[this.writeHead]
      this.writeHead = (this.writeHead + take) % QUEUE
      this.writeCount -= take
      this.writeBatches += 1
    }
  }

  /**
   * Binds `r`'s group, and every request batched after it, on `conn`. A write
   * whose binds might not fit beside what already waits on the connection is
   * not bound: the group ends before it, and it and the writes after it wait
   * in `deferred` for the next pump, so no write's bind is refused for room
   * (which would fail the group, or send the writes before it while their
   * requests answered 500). False when nothing could be bound or a bind was
   * refused.
   */
  bindAll(r: ConduitReq, conn: PgConnection): boolean {
    r.prefix = 0
    if (r.pool === POOL_WRITE && !r.solo && r.batchNext >= 0) {
      if (!this.foldFavorites(r, conn)) {
        return false
      }
    } else {
      // Alone (a write sent again after its batch failed, too), it makes its own write.
      r.folded = false
    }
    let prev: i32 = -1
    let k: i32 = r.index
    while (k >= 0) {
      const m: ConduitReq = this.reqs[k]
      if (
        m.pool === POOL_WRITE &&
        conn.outputEnd() - conn.outputStart() + writeCost(m) > PG_MAX_OUTPUT - 1024
      ) {
        if (prev >= 0) {
          this.reqs[prev].batchNext = -1
        }
        // Held back, they belong to no group: the group's own events (sent
        // with the statements dispatch prepared, or lost) answer none of them.
        let h: i32 = k
        while (h >= 0) {
          this.reqs[h].ticket = -1
          h = this.reqs[h].batchNext
        }
        this.deferred.push(k)
        return prev >= 0
      }
      if (!this.bind(m, conn)) {
        return false
      }
      prev = k
      k = m.batchNext
    }
    return true
  }

  /**
   * Folds the favorites and unfavorites of the batch `r` leads into one
   * statement of each kind, bound before the batch's own: a folded request
   * then reads its article only. A request is folded only when its slug is
   * text and no other favorite or unfavorite of the batch has its viewer, so
   * the order of one viewer's toggles is the order they came in. Both writes
   * are idempotent: one the batch holds back (`bindAll`) and sends again
   * gets the same answer. False when a bind was refused.
   */
  foldFavorites(r: ConduitReq, conn: PgConnection): boolean {
    let k: i32 = r.index
    let n: i32 = 0
    while (k >= 0) {
      const m: ConduitReq = this.reqs[k]
      m.folded = false
      if (m.route === R_FAVORITE || m.route === R_UNFAVORITE) {
        n += 1
      }
      k = m.batchNext
    }
    if (n < 2) {
      return true
    }
    let folds: i32 = 0
    k = r.index
    while (k >= 0) {
      const m: ConduitReq = this.reqs[k]
      if (m.route === R_FAVORITE || m.route === R_UNFAVORITE) {
        const start: i32 = m.fStart[F_PATH]
        const len: i32 = m.fLen[F_PATH]
        let alone: boolean = len > 0 && len <= PLAN_KEY_MAX && isText(m.text, start, start + len)
        let j: i32 = r.index
        while (alone && j >= 0) {
          const o: ConduitReq = this.reqs[j]
          if (j !== k && (o.route === R_FAVORITE || o.route === R_UNFAVORITE) && o.viewer === m.viewer) {
            alone = false
          }
          j = o.batchNext
        }
        m.folded = alone
        folds += alone ? 1 : 0
      }
      k = m.batchNext
    }
    if (folds < 2) {
      k = r.index
      while (k >= 0) {
        this.reqs[k].folded = false
        k = this.reqs[k].batchNext
      }
      return true
    }
    for (let kind: i32 = 0; kind < 2; kind++) {
      const route: i32 = kind === 0 ? R_FAVORITE : R_UNFAVORITE
      let any: boolean = false
      k = r.index
      while (k >= 0 && !any) {
        any = this.reqs[k].folded && this.reqs[k].route === route
        k = this.reqs[k].batchNext
      }
      if (!any) {
        continue
      }
      if (!conn.bindStart(kind === 0 ? "favorite_many" : "unfavorite_many") || !conn.arrayStart()) {
        return false
      }
      for (let half: i32 = 0; half < 2; half++) {
        if (half === 1 && !conn.arrayStart()) {
          return false
        }
        k = r.index
        while (k >= 0) {
          const m: ConduitReq = this.reqs[k]
          if (m.folded && m.route === route) {
            const ok: boolean =
              half === 0
                ? conn.arrayInt(m.viewer)
                : conn.arrayElement(m.text, m.fStart[F_PATH], m.fLen[F_PATH])
            if (!ok) {
              conn.arrayEnd()
              return false
            }
          }
          k = m.batchNext
        }
        conn.arrayEnd()
      }
      if (!conn.bindEnd()) {
        return false
      }
      r.prefix += 1
    }
    return true
  }

  /** How many statements `r`'s group runs, so a batch knows where each request's answers end. */
  statements(r: ConduitReq): i32 {
    switch (r.route) {
      case R_ARTICLE_CREATE:
        return r.tags > 0 ? 4 : 2
      case R_ARTICLE_PUT:
        return r.phase === 0 ? 1 : 2
      default:
        return 1
    }
  }

  pgFlush(conn: PgConnection, fd: i32): boolean {
    while (conn.outputEnd() > conn.outputStart()) {
      const n: i32 = netWrite(
        fd,
        conn.outputBuffer(),
        conn.outputStart(),
        conn.outputEnd() - conn.outputStart()
      )
      if (n === AGAIN) {
        return true
      }
      if (n <= 0) {
        return false
      }
      conn.sent(n)
    }
    return true
  }

  pgReady(p: i32, s: i32, events: i32): void {
    const socket: PgSocket = this.sockets[p][s]
    if (socket.fd < 0) {
      return
    }
    const conn: PgConnection = this.pools[p].connection(s)
    if (!socket.connected) {
      if (connectResult(socket.fd) === 0) {
        socket.connected = true
      } else {
        conn.closed()
      }
      this.pgEvents(p, s)
      return
    }
    if ((events & READABLE) !== 0) {
      // Read until the socket is empty or the buffer is full, then read the events.
      while (true) {
        let room: i32 = conn.inputRoom()
        if (room <= 0) {
          this.pgEvents(p, s)
          if (socket.fd < 0) {
            return
          }
          room = conn.inputRoom()
          if (room <= 0) {
            break
          }
        }
        const got: i32 = netRead(socket.fd, conn.inputBuffer(), conn.inputEnd(), room)
        if (got === AGAIN) {
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
        this.pgEvents(p, s)
        if (socket.fd < 0) {
          return
        }
      }
    }
    this.pgEvents(p, s)
  }

  /** Reads every event `p`'s slot `s` has. */
  pgEvents(p: i32, s: i32): void {
    const pool: PgPool = this.pools[p]
    const conn: PgConnection = pool.connection(s)
    let event: i32 = pool.next(s)
    while (event !== PG_NEED_MORE) {
      if (event === PG_FAILED) {
        const socket: PgSocket = this.sockets[p][s]
        if (socket.fd >= 0) {
          pollRemove(this.loop, socket.fd)
          netClose(socket.fd)
          socket.fd = -1
          socket.connected = false
        }
        this.current[p][s] = -1
        return
      }
      const ticket: i32 = pool.ticket
      if (ticket >= 0 && p === POOL_WRITE) {
        this.batchEvent(s, conn, ticket, event)
      } else if (ticket >= 0 && this.ticketPlan[ticket % TICKET_RING] >= 0) {
        this.planEvent(ticket, conn, event)
      } else if (ticket >= 0) {
        const ri: i32 = this.tickets[p][ticket % TICKET_RING]
        if (
          ri >= 0 &&
          ri < toI32(this.reqs.length) &&
          this.reqs[ri].inPool &&
          this.reqs[ri].pool === p &&
          this.reqs[ri].ticket === ticket
        ) {
          const r: ConduitReq = this.reqs[ri]
          const w: JsonWriter = this.writers[p][s]
          if (this.current[p][s] !== ticket) {
            this.current[p][s] = ticket
            this.begin(r, w, this.buffers[p][s])
          }
          if (event === PG_ROW) {
            this.onRow(r, conn, w)
          } else if (event === PG_COMPLETE) {
            r.stmt += 1
          } else if (event === PG_ERROR) {
            const code: string = conn.lastError?.code ?? ""
            r.pgError = code === "23505" ? 1 : 2
          } else if (event === PG_GROUP_DONE) {
            this.current[p][s] = -1
            this.tickets[p][ticket % TICKET_RING] = -1
            r.inPool = false
            if (conn.groupFailed || r.pgError !== 0) {
              this.onFailed(r)
            } else {
              this.onDone(r, w, this.buffers[p][s])
            }
          } else if (event === PG_LOST) {
            this.tickets[p][ticket % TICKET_RING] = -1
            this.current[p][s] = -1
            r.inPool = false
            this.fail(r, 500, "the database connection was lost", true)
          }
        }
      }
      event = pool.next(s)
    }
  }

  /**
   * One event of a write batch's group. The requests' statements are
   * answered in the order they were bound, so `writeCursor` walks the batch
   * as each request's last statement completes. Each request writes its own
   * answer; all of them go out once the group commits. A group that failed
   * rolled back every write in it, so each is sent again alone, and one sent
   * alone answers its error; a group lost with its connection may have
   * committed, so its writes answer 500 and are not sent again.
   */
  batchEvent(s: i32, conn: PgConnection, ticket: i32, event: i32): void {
    const leader: i32 = this.tickets[POOL_WRITE][ticket % TICKET_RING]
    if (
      leader < 0 ||
      leader >= toI32(this.reqs.length) ||
      this.reqs[leader].ticket !== ticket ||
      !this.reqs[leader].inPool
    ) {
      return
    }
    if (this.current[POOL_WRITE][s] !== ticket) {
      this.current[POOL_WRITE][s] = ticket
      this.writeCursor[s] = leader
      this.writePrefix[s] = this.reqs[leader].prefix
      const first: ConduitReq = this.reqs[leader]
      first.ownRoom(64)
      this.begin(first, first.ownWriter, first.own)
    }
    if (event === PG_GROUP_DONE || event === PG_LOST) {
      this.current[POOL_WRITE][s] = -1
      this.tickets[POOL_WRITE][ticket % TICKET_RING] = -1
      if (!this.reqs[leader].solo) {
        this.writeBatches -= 1
      }
      const failed: boolean = event === PG_LOST || conn.groupFailed
      const alone: boolean = this.reqs[leader].batchNext < 0
      let k: i32 = leader
      while (k >= 0) {
        const m: ConduitReq = this.reqs[k]
        k = m.batchNext
        m.batchNext = -1
        m.inPool = false
        if (event === PG_LOST) {
          this.fail(m, 500, "the database connection was lost", true)
        } else if (!failed && m.pgError === 0) {
          this.onDone(m, m.ownWriter, m.own)
        } else if (alone) {
          this.onFailed(m)
        } else {
          m.solo = true
          this.submit(m, true)
        }
      }
      return
    }
    if (this.writePrefix[s] > 0) {
      // The folded favorites' and unfavorites' statements answer no request;
      // one that fails fails the group, whose writes are then sent alone.
      if (event === PG_COMPLETE || event === PG_ERROR) {
        this.writePrefix[s] -= 1
      }
      return
    }
    const m: ConduitReq = this.reqs[this.writeCursor[s]]
    if (event === PG_ROW) {
      // `{` is all a write's answer holds before its row, so it is sized for the row now.
      let need: i32 = 1024
      for (let c: i32 = 0; c < conn.columns; c++) {
        need += 6 * (conn.colLength(c) > 0 ? conn.colLength(c) : 0) + 16
      }
      if (toI32(m.own.length) < need) {
        m.ownRoom(need)
        this.begin(m, m.ownWriter, m.own)
      }
      this.onRow(m, conn, m.ownWriter)
    } else if (event === PG_COMPLETE) {
      m.stmt += 1
      if (m.stmt >= this.statements(m) && m.batchNext >= 0) {
        const next: ConduitReq = this.reqs[m.batchNext]
        this.writeCursor[s] = next.index
        next.ownRoom(64)
        this.begin(next, next.ownWriter, next.own)
      }
    } else if (event === PG_ERROR) {
      const code: string = conn.lastError?.code ?? ""
      m.pgError = code === "23505" ? 1 : 2
    }
  }

  /** Binds `r`'s group on `conn`; false when a builder call refused. */
  bind(r: ConduitReq, conn: PgConnection): boolean {
    let ok: boolean = true
    switch (r.route) {
      case R_TAGS:
        ok = conn.bindStart("tags") && conn.bindEnd()
        break
      case R_USER_GET:
        ok = conn.bindStart("user_id") && conn.paramInt(r.viewer) && conn.bindEnd()
        break
      case R_LOGIN:
        ok = conn.bindStart("login") && this.text(conn, r, F_EMAIL) && conn.bindEnd()
        break
      case R_SIGNUP:
        ok =
          conn.bindStart("signup") &&
          this.text(conn, r, F_USERNAME) &&
          this.text(conn, r, F_EMAIL) &&
          this.text(conn, r, F_HASH) &&
          conn.bindEnd()
        break
      case R_USER_PUT:
        ok =
          conn.bindStart("user_update") &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_EMAIL) &&
          this.text(conn, r, F_USERNAME) &&
          this.text(conn, r, F_HASH) &&
          this.text(conn, r, F_BIO) &&
          this.text(conn, r, F_IMAGE) &&
          conn.bindEnd()
        break
      case R_PROFILE:
        ok =
          conn.bindStart("profile") && conn.paramInt(r.viewer) && this.text(conn, r, F_PATH) && conn.bindEnd()
        break
      case R_FOLLOW:
        ok =
          conn.bindStart("follow") && conn.paramInt(r.viewer) && this.text(conn, r, F_PATH) && conn.bindEnd()
        break
      case R_UNFOLLOW:
        ok =
          conn.bindStart("unfollow") &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_PATH) &&
          conn.bindEnd()
        break
      case R_LIST:
        ok = this.bindList(r, conn)
        break
      case R_FEED:
        ok =
          conn.bindStart("list_feed") &&
          conn.paramInt(r.viewer) &&
          conn.paramInt(r.limit) &&
          conn.paramInt(r.offset) &&
          conn.bindEnd() &&
          conn.bindStart("count_feed") &&
          conn.paramInt(r.viewer) &&
          conn.bindEnd()
        break
      case R_ARTICLE_GET:
        ok =
          conn.bindStart("article_slug") &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_PATH) &&
          conn.bindEnd()
        break
      case R_ARTICLE_CREATE:
        ok =
          conn.bindStart("article_create") &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_TITLE) &&
          this.text(conn, r, F_DESCRIPTION) &&
          this.text(conn, r, F_BODY) &&
          conn.bindEnd()
        if (ok && r.tags > 0) {
          ok =
            conn.bindStart("tags_create") &&
            this.text(conn, r, F_TAGS) &&
            conn.bindEnd() &&
            conn.bindStart("article_tags_create") &&
            this.text(conn, r, F_TAGS) &&
            conn.bindEnd()
        }
        ok = ok && conn.bindStart("article_last") && conn.paramInt(r.viewer) && conn.bindEnd()
        break
      case R_ARTICLE_PUT:
        if (r.phase === 0) {
          ok = conn.bindStart("article_owner") && this.text(conn, r, F_PATH) && conn.bindEnd()
        } else {
          ok =
            conn.bindStart("article_update") &&
            conn.paramInt(r.articleId) &&
            this.text(conn, r, F_TITLE) &&
            this.text(conn, r, F_DESCRIPTION) &&
            this.text(conn, r, F_BODY) &&
            conn.bindEnd() &&
            conn.bindStart("article_id") &&
            conn.paramInt(r.viewer) &&
            conn.paramInt(r.articleId) &&
            conn.bindEnd()
        }
        break
      case R_ARTICLE_DELETE:
        ok =
          conn.bindStart("article_delete") &&
          this.text(conn, r, F_PATH) &&
          conn.paramInt(r.viewer) &&
          conn.bindEnd()
        break
      case R_FAVORITE:
      case R_UNFAVORITE:
        // Phase 0 is the write (a folded one's was its batch's); phase 1 its
        // article, sent alone here only when a read plan could not answer it.
        if (r.phase === 1) {
          ok = conn.bindStart("article_slug") && conn.paramInt(r.viewer) && this.text(conn, r, F_PATH) && conn.bindEnd()
        } else if (r.folded) {
          ok = conn.bindStart("noop") && conn.bindEnd()
        } else {
          ok =
            conn.bindStart(r.route === R_FAVORITE ? "favorite" : "unfavorite") &&
            conn.paramInt(r.viewer) &&
            this.text(conn, r, F_PATH) &&
            conn.bindEnd()
        }
        break
      case R_COMMENTS:
        ok =
          conn.bindStart("comments") &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_PATH) &&
          conn.bindEnd()
        break
      case R_COMMENT_CREATE:
        ok =
          conn.bindStart("comment_create") &&
          this.text(conn, r, F_PATH) &&
          conn.paramInt(r.viewer) &&
          this.text(conn, r, F_BODY) &&
          conn.bindEnd()
        break
      case R_COMMENT_DELETE:
        ok =
          conn.bindStart("comment_delete") &&
          conn.paramInt(r.commentId) &&
          this.text(conn, r, F_PATH) &&
          conn.paramInt(r.viewer) &&
          conn.bindEnd()
        break
      default:
        ok = false
    }
    return ok
  }

  bindList(r: ConduitReq, conn: PgConnection): boolean {
    if (r.filter === FILTER_NONE) {
      return (
        conn.bindStart("list_all") &&
        conn.paramInt(r.viewer) &&
        conn.paramInt(r.limit) &&
        conn.paramInt(r.offset) &&
        conn.bindEnd() &&
        conn.bindStart("count_all") &&
        conn.bindEnd()
      )
    }
    let list: string = "list_favorited"
    let count: string = "count_favorited"
    if (r.filter === FILTER_TAG) {
      list = "list_tag"
      count = "count_tag"
    } else if (r.filter === FILTER_AUTHOR) {
      list = "list_author"
      count = "count_author"
    }
    return (
      conn.bindStart(list) &&
      conn.paramInt(r.viewer) &&
      conn.paramInt(r.limit) &&
      conn.paramInt(r.offset) &&
      this.text(conn, r, F_FILTER) &&
      conn.bindEnd() &&
      conn.bindStart(count) &&
      this.text(conn, r, F_FILTER) &&
      conn.bindEnd()
    )
  }

  /** Field `f` as a text parameter, NULL when absent. */
  text(conn: PgConnection, r: ConduitReq, f: i32): boolean {
    const len: i32 = r.fLen[f]
    return len < 0 ? conn.paramNull() : conn.paramBytes(r.text, r.fStart[f], len)
  }

  // ---- Rows into JSON -------------------------------------------------------------

  /** Starts the answer of `r`'s group in `w`. */
  begin(r: ConduitReq, w: JsonWriter, buf: u8[]): void {
    w.reset(buf, 0)
    w.beginObject()
    const route: i32 = r.route
    if (route === R_TAGS) {
      w.key("tags")
    } else if (route === R_LIST || route === R_FEED) {
      w.key("articles")
      w.beginArray()
    } else if (route === R_COMMENTS) {
      w.key("comments")
      w.beginArray()
    }
  }

  onRow(r: ConduitReq, conn: PgConnection, w: JsonWriter): void {
    switch (r.route) {
      case R_TAGS:
        this.tagList(w, conn, 0)
        break
      case R_LIST:
      case R_FEED:
        if (r.stmt === 0) {
          this.article(w, conn, false)
        } else {
          r.count = conn.int(0)
        }
        break
      case R_ARTICLE_GET:
        this.mainArticle(r, w, conn)
        break
      case R_FAVORITE:
      case R_UNFAVORITE:
        // Only phase 1, the article read alone, has a row to write.
        if (r.phase === 1) {
          this.mainArticle(r, w, conn)
        }
        break
      case R_ARTICLE_CREATE:
        if (r.stmt === (r.tags > 0 ? 3 : 1)) {
          this.mainArticle(r, w, conn)
        }
        break
      case R_ARTICLE_PUT:
        if (r.phase === 0) {
          r.articleId = conn.int(0)
          r.authorId = conn.int(1)
          r.found = true
        } else if (r.stmt === 1) {
          this.mainArticle(r, w, conn)
        }
        break
      case R_ARTICLE_DELETE:
      case R_COMMENT_DELETE:
        r.authorId = conn.int(0)
        r.found = true
        break
      case R_COMMENTS:
        // The article's row; its comment columns are NULL when it has none.
        r.found = true
        if (!conn.isNull(1)) {
          this.comment(w, conn, 1, 8)
        }
        break
      case R_COMMENT_CREATE:
        if (!r.found) {
          r.found = true
          w.key("comment")
          this.comment(w, conn, 0, -1)
        }
        break
      case R_PROFILE:
      case R_FOLLOW:
      case R_UNFOLLOW:
        if (!r.found) {
          r.found = true
          w.key("profile")
          w.beginObject()
          w.key("username")
          this.column(w, conn, 0)
          w.key("bio")
          this.column(w, conn, 1)
          w.key("image")
          this.column(w, conn, 2)
          w.key("following")
          w.boolean(r.route === R_PROFILE ? conn.bool(3) : r.route === R_FOLLOW)
          w.endObject()
        }
        break
      case R_USER_GET:
      case R_USER_PUT:
        if (!r.found) {
          r.found = true
          this.user(w, conn, r.text, r.fStart[F_TOKEN], r.fLen[F_TOKEN])
        }
        break
      case R_SIGNUP:
        if (!r.found) {
          r.found = true
          const n: i32 = this.jwt.issue(conn.int(0), toI64(Date.now()) / 1000, this.tokenBuf, 0)
          this.user(w, conn, this.tokenBuf, 0, n)
        }
        break
      case R_LOGIN:
        if (!r.found) {
          r.found = true
          r.userId = conn.int(0)
          r.setField(F_USERNAME, conn.inputBuffer(), conn.colStart(1), conn.colLength(1))
          r.setField(F_EMAIL, conn.inputBuffer(), conn.colStart(2), conn.colLength(2))
          if (conn.colLength(3) >= 0) {
            r.setField(F_BIO, conn.inputBuffer(), conn.colStart(3), conn.colLength(3))
          }
          if (conn.colLength(4) >= 0) {
            r.setField(F_IMAGE, conn.inputBuffer(), conn.colStart(4), conn.colLength(4))
          }
          r.setField(F_HASH, conn.inputBuffer(), conn.colStart(5), conn.colLength(5))
        }
        break
      default:
        break
    }
  }

  /** The `article` key and object of a single-article answer, once. */
  mainArticle(r: ConduitReq, w: JsonWriter, conn: PgConnection): void {
    if (!r.found) {
      r.found = true
      w.key("article")
      this.article(w, conn, true)
    }
  }

  /** Column `c` as a JSON string, or null. */
  column(w: JsonWriter, conn: PgConnection, c: i32): void {
    const len: i32 = conn.colLength(c)
    if (len < 0) {
      w.nullValue()
    } else {
      w.stringBytes(conn.inputBuffer(), conn.colStart(c), len)
    }
  }

  /** A `timestamptz` column as RFC 3339 with milliseconds, truncated. */
  timestamp(w: JsonWriter, conn: PgConnection, c: i32): void {
    const n: i32 = conn.text.timestamp(conn.inputBuffer(), conn.colStart(c), conn.colLength(c), this.stamp, 0)
    if (n < 0) {
      w.nullValue()
    } else {
      w.stringBytes(this.stamp, 0, n)
    }
  }

  /**
   * An article row (`COL_` order) as an Article object: written by
   * `articleBytes` into `rowBuf` and added as one value, or through the
   * writer's own calls when that answers -1.
   */
  article(w: JsonWriter, conn: PgConnection, full: boolean): void {
    const n: i32 = this.articleBytes(conn, full)
    if (n >= 0) {
      w.raw(this.rowBuf, 0, n)
    } else {
      this.articleWriter(w, conn, full)
    }
  }

  /**
   * The article row as JSON at `rowBuf[0]`, its fixed text copied from
   * `fragments` and only its values encoded; answers the length, or -1 when
   * the row might not fit, a timestamp does not read, or the tag list needs
   * the walker.
   */
  articleBytes(conn: PgConnection, full: boolean): i32 {
    const b: u8[] = conn.inputBuffer()
    const out: u8[] = this.rowBuf
    const f: u8[][] = this.fragments
    let worst: i32 = 512 + 2 * conn.colLength(COL_TAGS)
    const strings: i32[] = this.stringColumns
    for (let k: i32 = 0; k < toI32(strings.length); k++) {
      const c: i32 = strings[k]
      if (c !== COL_BODY || full) {
        worst += jsonOutWorst(conn.colLength(c))
      }
    }
    if (
      worst > toI32(out.length) ||
      conn.isNull(COL_SLUG) ||
      conn.isNull(COL_TITLE) ||
      conn.isNull(COL_DESCRIPTION) ||
      conn.isNull(COL_USERNAME)
    ) {
      return -1
    }
    let o: i32 = jsonOutRaw(out, 0, f[0])
    o = jsonOutString(out, o, b, conn.colStart(COL_SLUG), conn.colLength(COL_SLUG))
    o = jsonOutRaw(out, o, f[1])
    o = jsonOutString(out, o, b, conn.colStart(COL_TITLE), conn.colLength(COL_TITLE))
    o = jsonOutRaw(out, o, f[2])
    o = jsonOutString(out, o, b, conn.colStart(COL_DESCRIPTION), conn.colLength(COL_DESCRIPTION))
    if (full) {
      if (conn.isNull(COL_BODY)) {
        return -1
      }
      o = jsonOutRaw(out, o, f[3])
      o = jsonOutString(out, o, b, conn.colStart(COL_BODY), conn.colLength(COL_BODY))
    }
    o = jsonOutRaw(out, o, f[4])
    o = jsonOutTextArray(out, o, b, conn.colStart(COL_TAGS), conn.colLength(COL_TAGS))
    if (o < 0) {
      return -1
    }
    o = jsonOutRaw(out, o, f[5])
    if (conn.text.timestamp(b, conn.colStart(COL_CREATED), conn.colLength(COL_CREATED), out, o) !== 24) {
      return -1
    }
    o = jsonOutRaw(out, o + 24, f[6])
    if (conn.text.timestamp(b, conn.colStart(COL_UPDATED), conn.colLength(COL_UPDATED), out, o) !== 24) {
      return -1
    }
    o = jsonOutRaw(out, o + 24, f[7])
    o = jsonOutBool(out, o, conn.bool(COL_FAVORITED))
    o = jsonOutRaw(out, o, f[8])
    o = jwtDigits(conn.int(COL_FAVORITES), out, o)
    o = jsonOutRaw(out, o, f[9])
    o = jsonOutString(out, o, b, conn.colStart(COL_USERNAME), conn.colLength(COL_USERNAME))
    o = jsonOutRaw(out, o, f[10])
    o = conn.isNull(COL_BIO)
      ? jsonOutNull(out, o)
      : jsonOutString(out, o, b, conn.colStart(COL_BIO), conn.colLength(COL_BIO))
    o = jsonOutRaw(out, o, f[11])
    o = conn.isNull(COL_IMAGE)
      ? jsonOutNull(out, o)
      : jsonOutString(out, o, b, conn.colStart(COL_IMAGE), conn.colLength(COL_IMAGE))
    o = jsonOutRaw(out, o, f[12])
    o = jsonOutBool(out, o, conn.bool(COL_FOLLOWING))
    return jsonOutRaw(out, o, f[13])
  }

  /** `article` through the writer's calls, for a row `articleBytes` does not take. */
  articleWriter(w: JsonWriter, conn: PgConnection, full: boolean): void {
    w.beginObject()
    w.key("slug")
    this.column(w, conn, COL_SLUG)
    w.key("title")
    this.column(w, conn, COL_TITLE)
    w.key("description")
    this.column(w, conn, COL_DESCRIPTION)
    if (full) {
      w.key("body")
      this.column(w, conn, COL_BODY)
    }
    w.key("tagList")
    this.tagList(w, conn, COL_TAGS)
    w.key("createdAt")
    this.timestamp(w, conn, COL_CREATED)
    w.key("updatedAt")
    this.timestamp(w, conn, COL_UPDATED)
    w.key("favorited")
    w.boolean(conn.bool(COL_FAVORITED))
    w.key("favoritesCount")
    w.i64(conn.int(COL_FAVORITES))
    w.key("author")
    w.beginObject()
    w.key("username")
    this.column(w, conn, COL_USERNAME)
    w.key("bio")
    this.column(w, conn, COL_BIO)
    w.key("image")
    this.column(w, conn, COL_IMAGE)
    w.key("following")
    w.boolean(conn.bool(COL_FOLLOWING))
    w.endObject()
    w.endObject()
  }

  /**
   * The `text[]` column `c` as a JSON array of strings: in one pass of block
   * copies when `jsonOutTextArray` takes it, element by element with
   * `PgArrayWalker` otherwise.
   */
  tagList(w: JsonWriter, conn: PgConnection, c: i32): void {
    const b: u8[] = conn.inputBuffer()
    const start: i32 = conn.colStart(c)
    const len: i32 = conn.colLength(c)
    const out: u8[] = this.scratch
    if (len >= 2 && 2 * len + 2 <= toI32(out.length)) {
      const n: i32 = jsonOutTextArray(out, 0, b, start, len)
      if (n >= 0) {
        w.raw(out, 0, n)
        return
      }
    }
    w.beginArray()
    const walker: PgArrayWalker = this.walker
    walker.begin(b, start, len)
    let e: i32 = walker.next()
    while (e === PG_ARRAY_ELEMENT || e === PG_ARRAY_NULL) {
      if (e === PG_ARRAY_NULL) {
        w.nullValue()
      } else if (walker.escaped) {
        const n: i32 = walker.copy(out, 0)
        w.stringBytes(out, 0, n < 0 ? 0 : n)
      } else {
        w.stringBytes(b, walker.start, walker.length)
      }
      e = walker.next()
    }
    w.endArray()
  }

  /**
   * The comment columns from `at` on (id, body, created, updated, username,
   * bio, image) as a Comment object; `following` is column `followingAt`, or
   * false when that is -1.
   */
  comment(w: JsonWriter, conn: PgConnection, at: i32, followingAt: i32): void {
    w.beginObject()
    w.key("id")
    w.i64(conn.int(at))
    w.key("createdAt")
    this.timestamp(w, conn, at + 2)
    w.key("updatedAt")
    this.timestamp(w, conn, at + 3)
    w.key("body")
    this.column(w, conn, at + 1)
    w.key("author")
    w.beginObject()
    w.key("username")
    this.column(w, conn, at + 4)
    w.key("bio")
    this.column(w, conn, at + 5)
    w.key("image")
    this.column(w, conn, at + 6)
    w.key("following")
    w.boolean(followingAt >= 0 ? conn.bool(followingAt) : false)
    w.endObject()
    w.endObject()
  }

  /** A user row (id, username, email, bio, image) as `"user": User`, with the token `tok[off, off + len)`. */
  user(w: JsonWriter, conn: PgConnection, tok: u8[], off: i32, len: i32): void {
    w.key("user")
    w.beginObject()
    w.key("email")
    this.column(w, conn, 2)
    w.key("token")
    w.stringBytes(tok, off, len)
    w.key("username")
    this.column(w, conn, 1)
    w.key("bio")
    this.column(w, conn, 3)
    w.key("image")
    this.column(w, conn, 4)
    w.endObject()
  }

  /** `r`'s group failed: a unique violation where SPEC.md makes it 422, else 500. */
  onFailed(r: ConduitReq): void {
    if (r.pgError === 1 && (r.route === R_SIGNUP || r.route === R_USER_PUT)) {
      this.fail(r, 422, "taken", true)
    } else {
      this.fail(r, 500, "database error", true)
    }
  }

  /** `r`'s group committed: answer it, or start its next phase. */
  onDone(r: ConduitReq, w: JsonWriter, buf: u8[]): void {
    const route: i32 = r.route
    switch (route) {
      case R_TAGS:
        w.endObject()
        this.answerWritten(r, 200, w, buf)
        return
      case R_LIST:
      case R_FEED:
        w.endArray()
        w.key("articlesCount")
        w.i64(r.count)
        w.endObject()
        this.answerWritten(r, 200, w, buf)
        return
      case R_COMMENTS:
        if (!r.found) {
          this.fail(r, 404, "article not found", true)
          return
        }
        w.endArray()
        w.endObject()
        this.answerWritten(r, 200, w, buf)
        return
      case R_LOGIN:
        if (!r.found) {
          wipe(r.pw)
          this.fail(r, 401, "invalid credentials", true)
          return
        }
        this.toBcrypt(r, BCRYPT_OP_VERIFY, true)
        return
      case R_FAVORITE:
      case R_UNFAVORITE:
        if (r.phase === 0) {
          // The write has committed: its article is read by the next read plan.
          r.phase = 1
          r.solo = false
          this.submit(r, true)
          return
        }
        break
      case R_ARTICLE_PUT:
        if (r.phase === 0) {
          if (!r.found) {
            this.fail(r, 404, "article not found", true)
          } else if (r.authorId !== r.viewer) {
            this.fail(r, 403, "not the author", true)
          } else {
            r.phase = 1
            this.submit(r, true)
          }
          return
        }
        break
      case R_ARTICLE_DELETE:
      case R_COMMENT_DELETE:
        if (!r.found) {
          this.fail(r, 404, "not found", true)
        } else if (r.authorId !== r.viewer) {
          this.fail(r, 403, "not the author", true)
        } else {
          this.answer(r, 204, buf, 0, true)
        }
        return
      default:
        break
    }
    if (!r.found) {
      const missing: i32 = route === R_USER_GET || route === R_USER_PUT ? 401 : 404
      this.fail(r, missing, missing === 401 ? "unauthorized" : "not found", true)
      return
    }
    w.endObject()
    const created: boolean = route === R_SIGNUP || route === R_ARTICLE_CREATE || route === R_COMMENT_CREATE
    this.answerWritten(r, created ? 201 : 200, w, buf)
  }

  // ---- bcrypt ---------------------------------------------------------------------

  /**
   * The bcrypt service the next job goes to: the one whose batch is the
   * closest to full without being full, so a service's lanes fill
   * before the next is given work; and while every batch is full, the least
   * busy. Several services each get the box's fair share of a core when
   * Postgres keeps every core busy, where one alone fell behind the logins.
   */
  bcryptPick(): i32 {
    let up: boolean = false
    for (const c of this.bcrypts) {
      up = up || !c.down
    }
    let best: i32 = -1
    let bestPart: i32 = 0
    let idle: i32 = -1
    for (let k: i32 = 0; k < toI32(this.bcrypts.length); k++) {
      const c: BcryptClient = this.bcrypts[k]
      if (up && c.down) {
        continue
      }
      const part: i32 = c.inFlight % this.bcryptWidth
      if (part > bestPart) {
        bestPart = part
        best = k
      }
      if (idle < 0 || c.inFlight < this.bcrypts[idle].inFlight) {
        idle = k
      }
    }
    return best >= 0 ? best : idle
  }

  /** Connects to every bcrypt service at start, so one that is not there is known down before a login needs it. */
  bcryptStart(): void {
    for (let k: i32 = 0; k < toI32(this.bcrypts.length); k++) {
      this.bcryptConnect(k)
    }
  }

  /** Sends `r`'s password to a bcrypt service: a new hash, or a check against `F_HASH`. */
  toBcrypt(r: ConduitReq, op: i32, later: boolean): void {
    const k: i32 = this.bcryptPick()
    const c: BcryptClient = this.bcrypts[k]
    const hashLen: i32 = op === BCRYPT_OP_VERIFY ? r.fLen[F_HASH] : 0
    const queued: boolean = c.request(op, r.index, r.pw, r.pwLen, r.text, r.fStart[F_HASH], hashLen < 0 ? 0 : hashLen)
    wipe(r.pw)
    r.pwLen = -1
    if (!queued) {
      this.fail(r, 503, "busy", later)
      return
    }
    r.inBcrypt = true
    r.bcryptAt = k
    c.inFlight += 1
    if (c.fd < 0) {
      if (c.retryAt === 0) {
        this.bcryptConnect(k)
      }
    } else if (c.connected) {
      if (!c.send()) {
        this.bcryptLost(k)
      } else {
        pollModify(this.loop, c.fd, c.outputEnd > c.outputStart ? 3 : 1, TOKEN_BCRYPT - k)
      }
    }
  }

  bcryptConnect(k: i32): void {
    const c: BcryptClient = this.bcrypts[k]
    const fd: i32 = tcpConnect(c.address)
    if (fd < 0 || pollAdd(this.loop, fd, H1_WANT_WRITE, TOKEN_BCRYPT - k) < 0) {
      if (fd >= 0) {
        netClose(fd)
      }
      this.bcryptRefused(k)
      return
    }
    c.fd = fd
    c.connected = false
  }

  /**
   * A connect failed. Nothing has been sent, so the requests wait in the
   * output and the connect is tried again shortly, for `BCRYPT_PATIENCE`
   * (the service may still be starting); then they fail.
   */
  bcryptRefused(k: i32): void {
    const c: BcryptClient = this.bcrypts[k]
    const now: i64 = monotonicNanos()
    if (c.down) {
      // Tried again once a second; its jobs went to the others meanwhile.
      c.retryAt = now + 1000000000
      return
    }
    if (c.failedAt === 0) {
      c.failedAt = now
    }
    if (now - c.failedAt > BCRYPT_PATIENCE) {
      c.failedAt = 0
      this.bcryptLost(k)
      c.down = true
      c.retryAt = now + 1000000000
      return
    }
    c.retryAt = now + 50000000
  }

  bcryptTick(): void {
    const now: i64 = monotonicNanos()
    for (let k: i32 = 0; k < toI32(this.bcrypts.length); k++) {
      const c: BcryptClient = this.bcrypts[k]
      if (c.retryAt > 0 && now >= c.retryAt && c.fd < 0) {
        c.retryAt = 0
        this.bcryptConnect(k)
      }
    }
  }

  /** Service `k` went away with requests on it: they fail, since their passwords are gone. */
  bcryptLost(k: i32): void {
    const c: BcryptClient = this.bcrypts[k]
    if (c.fd >= 0) {
      pollRemove(this.loop, c.fd)
      netClose(c.fd)
    }
    c.reset()
    for (const r of this.reqs) {
      if (r.inBcrypt && r.bcryptAt === k) {
        r.inBcrypt = false
        r.bcryptAt = -1
        this.fail(r, 500, "the password service is unavailable", true)
      }
    }
  }

  bcryptReady(k: i32, events: i32): void {
    const c: BcryptClient = this.bcrypts[k]
    if (c.fd < 0) {
      return
    }
    if (!c.connected) {
      if (connectResult(c.fd) !== 0) {
        pollRemove(this.loop, c.fd)
        netClose(c.fd)
        c.fd = -1
        this.bcryptRefused(k)
        return
      }
      c.connected = true
      c.failedAt = 0
      c.down = false
    }
    if ((events & READABLE) !== 0) {
      if (!c.receive()) {
        this.bcryptLost(k)
        return
      }
      while (c.nextReply()) {
        const ri: i32 = c.replyId
        if (ri >= 0 && ri < toI32(this.reqs.length) && this.reqs[ri].inBcrypt && this.reqs[ri].bcryptAt === k) {
          c.inFlight -= 1
          this.onBcrypt(this.reqs[ri], c)
        }
      }
    }
    if (!c.send()) {
      this.bcryptLost(k)
      return
    }
    pollModify(this.loop, c.fd, c.outputEnd > c.outputStart ? 3 : 1, TOKEN_BCRYPT - k)
  }

  onBcrypt(r: ConduitReq, c: BcryptClient): void {
    r.inBcrypt = false
    r.bcryptAt = -1
    if (r.route === R_LOGIN) {
      if (c.replyStatus !== BCRYPT_DONE) {
        this.fail(r, 401, "invalid credentials", true)
        return
      }
      // The fields are the user's own, uncapped (a bio of any length), so the
      // answer is sized from them rather than written into `plainBuf`.
      r.ownRoom(1024 + 6 * r.textEnd)
      const w: JsonWriter = r.ownWriter
      w.beginObject()
      w.key("user")
      w.beginObject()
      w.key("email")
      this.field(w, r, F_EMAIL)
      w.key("token")
      const n: i32 = this.jwt.issue(r.userId, toI64(Date.now()) / 1000, this.tokenBuf, 0)
      w.stringBytes(this.tokenBuf, 0, n)
      w.key("username")
      this.field(w, r, F_USERNAME)
      w.key("bio")
      this.field(w, r, F_BIO)
      w.key("image")
      this.field(w, r, F_IMAGE)
      w.endObject()
      w.endObject()
      this.answerWritten(r, 200, w, r.own)
      return
    }
    if (c.replyStatus !== BCRYPT_DONE) {
      this.fail(r, 500, "hashing failed", true)
      return
    }
    r.setField(F_HASH, c.replyHash, 0, c.replyHashLength)
    this.submit(r, true)
  }

  field(w: JsonWriter, r: ConduitReq, f: i32): void {
    if (r.fLen[f] < 0) {
      w.nullValue()
    } else {
      w.stringBytes(r.text, r.fStart[f], r.fLen[f])
    }
  }
}
