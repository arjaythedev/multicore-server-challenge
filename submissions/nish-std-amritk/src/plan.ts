// A read plan: the tag list, list pages, feeds, articles and comments that
// wait together, answered from a few statements over arrays of their
// distinct keys, in two pipelined groups.
//
// Group A finds what each request is about: one statement for each kind of
// list present answers its pages (each distinct filter, key, limit and
// offset once, as an array of article ids and one of their authors) and its
// capped counts (each distinct key once); an article by slug is its id and
// author (each distinct slug once); comments by slug are the comments (each
// distinct slug once); and every tag is read once, by name, for the tag
// list and for the names of every article's tags. Group B reads the rest
// once for the whole plan: the article columns of the union of every id
// group A answered, and the viewers' flags, `favorited` and `following`, one
// index range scan per viewer over its ids (`= ANY`) rather than one probe
// per article. Each request is then written from those rows, and nothing
// outlives the plan: every value a response holds was read while that
// request waited.
//
// Answering the pages and counts of a batch from one statement over their
// distinct keys, enriching the union of the articles once per batch, the
// per-viewer `= ANY` flags, and gathering a batch for a window (the worker's
// batch clock), are ideas from the challenge's rust-epoll-WorriedArrow
// submission; the SQL and this code are written here.
import { copyBytes } from "nish/bytes"
import {
  PG_ARRAY_ELEMENT,
  PG_ARRAY_END,
  PG_BATCH_DONE,
  PG_BATCH_MISSING,
  PG_BATCH_NONE,
  PG_BATCH_ROW,
  PG_COMPLETE,
  PG_ERROR,
  PG_ROW,
  PgBatcher,
  PgBinary,
  PgBinaryArray,
  PgConnection,
} from "nish/net/postgres"
import { jsonOutBool, jsonOutNull, jsonOutRaw, jsonOutString, jsonOutWorst } from "./json-out"
import { jwtDigits } from "./jwt"
import { planArticleBatch, planCommentBatch, planProfileBatch } from "./sql"

/** The kinds of request a plan answers: the five lists, an article and its comments by slug, the tag list, and a profile by username. */
export const K_GLOBAL: i32 = 0
export const K_TAG: i32 = 1
export const K_AUTHOR: i32 = 2
export const K_FAVORITED: i32 = 3
export const K_FEED: i32 = 4
export const K_ARTICLE: i32 = 5
export const K_COMMENTS: i32 = 6
export const K_TAGS: i32 = 7
export const K_PROFILE: i32 = 8
const LIST_KINDS: i32 = 5
const KINDS: i32 = 9
/** The largest tag id a plan places by rank; a plan that meets a larger one sends its requests alone. */
const TAG_ID_MAX: i32 = 1048576

/** The most requests one plan takes, and the most bytes of keys. */
export const PLAN_MAX: i32 = 256
export const PLAN_KEY_BYTES: i32 = 24576

/** `render`'s answer for a request the plan could not answer: send it alone. */
export const PLAN_ALONE: i32 = -1

/** The statements of group A, by kind, and of group B. */
const listStatement = (kind: i32): string => {
  if (kind === K_GLOBAL) {
    return "plan_global"
  }
  if (kind === K_TAG) {
    return "plan_tag"
  }
  if (kind === K_AUTHOR) {
    return "plan_author"
  }
  return kind === K_FAVORITED ? "plan_favorited" : "plan_feed"
}
const S_META: i32 = 100
const S_FLAGS: i32 = 101

/** The hash tables: a power of two at least twice what they hold. */
const TABLE: i32 = 1024
const ID_TABLE: i32 = 65536

/**
 * An article's columns in a `plan_meta` row. Its tags are their ids: their
 * names, and their order, come from the plan's one read of every tag by name.
 */
const M_ID: i32 = 0
const M_SLUG: i32 = 1
const M_TITLE: i32 = 2
const M_DESCRIPTION: i32 = 3
const M_TAGS: i32 = 4
const M_CREATED: i32 = 5
const M_UPDATED: i32 = 6
const M_USERNAME: i32 = 7
const M_BIO: i32 = 8
const M_IMAGE: i32 = 9
const M_BODY: i32 = 10

/** A comment's columns in a `plan_comments` row: the article's id first, NULL comment columns when it has none. */
const C_ID: i32 = 1
const C_BODY: i32 = 2
const C_CREATED: i32 = 3
const C_UPDATED: i32 = 4
const C_AUTHOR: i32 = 5
const C_USERNAME: i32 = 6
const C_BIO: i32 = 7
const C_IMAGE: i32 = 8

/** A profile's columns in a `plan_profile` row. */
const P_ID: i32 = 0
const P_USERNAME: i32 = 1
const P_BIO: i32 = 2
const P_IMAGE: i32 = 3

const planBytes = (s: string): u8[] => {
  const out: u8[] = new Array<u8>(s.length)
  for (let k: i32 = 0; k < toI32(s.length) && k < toI32(out.length); k++) {
    out[k] = toU8(s.charCodeAt(k))
  }
  return out
}

/** Grows `a` to hold at least `n` bytes, keeping its first `keep`. */
const grownBytes = (a: u8[], n: i32, keep: i32): u8[] => {
  if (n <= toI32(a.length)) {
    return a
  }
  let size: i32 = toI32(a.length) < 4096 ? 4096 : toI32(a.length)
  while (size < n) {
    size = size * 2
  }
  const out: u8[] = new Array<u8>(size)
  copyBytes(out, 0, a, 0, keep)
  return out
}

const grownInts = (a: i64[], n: i32, keep: i32): i64[] => {
  if (n <= toI32(a.length)) {
    return a
  }
  let size: i32 = toI32(a.length) < 1024 ? 1024 : toI32(a.length)
  while (size < n) {
    size = size * 2
  }
  const out: i64[] = new Array<i64>(size)
  for (let k: i32 = 0; k < keep && k < toI32(a.length) && k < size; k++) {
    out[k] = a[k]
  }
  return out
}

/** FNV-1a over the eight bytes of `v`, onto `h`; an unsigned multiply wraps by definition. */
const hashInt = (h: u32, v: i64): u32 => {
  let x: u32 = h
  let rest: i64 = v
  for (let k: i32 = 0; k < 8; k++) {
    x = (x ^ toU32(toI32(rest & toI64(255)))) * 16777619
    rest = rest >> toI64(8)
  }
  return x
}
/** FNV-1a's offset basis. */
const fnv = (): u32 => {
  const basis: u32 = 2166136261
  return basis
}
/** A hash as a non-negative i32, for a table index. */
const slotOf = (h: u32): i32 => toI32(h >> 1)

/** One read plan's requests, keys, rows and answers; reused plan after plan. */
/** The most distinct articles one count run takes; a plan past it goes alone. */
const COUNT_MAX: i32 = 65536
/** Twice `COUNT_MAX`, a power of two: the open-addressed table of a run's articles. */
const COUNT_TABLE: i32 = 131072

/**
 * One statement of a worker's count lane: the union of the articles of every
 * plan waiting when it starts, each counted once.
 *
 * Favorite counts are the one column of a plan that costs by the row walked
 * rather than by the article, and a popular article is on the pages of plan
 * after plan: on the VM at 145,000 users, 54% of the index entries a plan
 * counted had been counted for the same article in the 30 ms before. So they
 * leave `plan_meta` for a lane of their own. A worker runs one `plan_counts`
 * at a time, and the plans that finish group A meanwhile wait for the next,
 * which takes them all, however many; the plans themselves stay concurrent.
 * A run is fixed only as it is bound, so every count is read after the
 * requests it answers arrived, and a run keeps nothing once its plans have
 * their counts.
 */
export class CountRun {
  /** The plans waiting for this run, by their place in the worker's plans. */
  plans: i32[]
  ids: i64[]
  counts: i64[]
  private readonly table: i32[]
  private readonly slots: i32[]
  n: i32 = 0
  /** Its statement could not be bound: its plans go alone. */
  failed: boolean = false

  constructor() {
    this.plans = []
    this.ids = new Array<i64>(COUNT_MAX)
    this.counts = new Array<i64>(COUNT_MAX)
    this.slots = new Array<i32>(COUNT_MAX)
    this.table = new Array<i32>(COUNT_TABLE)
  }

  private slot(id: i64): i32 {
    const mask: i32 = COUNT_TABLE - 1
    let at: i32 = slotOf(hashInt(fnv(), id)) & mask
    while (this.table[at] > 0 && this.ids[this.table[at] - 1] !== id) {
      at = (at + 1) & mask
    }
    return at
  }

  /** Takes plan `p`'s articles; false, with none taken for good, when the run has no room for them. */
  join(p: i32, plan: ReadPlan): boolean {
    if (this.n + plan.metas > COUNT_MAX) {
      return false
    }
    for (let k: i32 = 0; k < plan.metas; k++) {
      const id: i64 = plan.metaIds[k]
      const at: i32 = this.slot(id)
      if (this.table[at] === 0) {
        this.ids[this.n] = id
        this.counts[this.n] = toI64(0)
        this.slots[this.n] = at
        this.n += 1
        this.table[at] = this.n
      }
    }
    this.plans.push(p)
    return true
  }

  /** `id`'s count, read by the run that held it. */
  count(id: i64): i64 {
    const at: i32 = this.table[this.slot(id)]
    return at > 0 ? this.counts[at - 1] : toI64(0)
  }

  bind(conn: PgConnection): boolean {
    return conn.bindStartBinary("plan_counts") && conn.paramIntArray(this.ids, 0, this.n) && conn.bindEnd()
  }

  /** A row of `plan_counts`: (id, count). */
  event(conn: PgConnection, event: i32): void {
    if (event === PG_ROW) {
      const at: i32 = this.table[this.slot(conn.binaryInt(0))]
      if (at > 0) {
        this.counts[at - 1] = conn.binaryInt(1)
      }
    }
  }

  /** Empties the run for the plans that come next. */
  reset(): void {
    for (let k: i32 = 0; k < this.n; k++) {
      this.table[this.slots[k]] = 0
    }
    this.n = 0
    this.failed = false
    this.plans = []
  }
}

export class ReadPlan {
  /** Each request: the caller's tag, its kind, viewer, limit, offset and key (a window of `keys`). */
  readonly tags: i32[]
  readonly kinds: i32[]
  readonly viewers: i64[]
  readonly limits: i64[]
  readonly offsets: i64[]
  readonly keyStarts: i32[]
  readonly keyLens: i32[]
  /** Each request's page key and count key (indices of `pageRep` and `countRep`), or -1. */
  readonly pageOf: i32[]
  readonly countOf: i32[]
  count: i32 = 0
  keys: u8[]
  keyEnd: i32 = 0
  /**
   * The distinct page keys and count keys, by the request that stands for
   * each, and each one's kind and place (1-based) in its kind's statement.
   */
  readonly pageRep: i32[]
  readonly pagePlace: i32[]
  readonly countRep: i32[]
  readonly countPlace: i32[]
  pages: i32 = 0
  counts: i32 = 0
  /** Per kind, the page and count keys it binds, in order: `kindPages[kind * PLAN_MAX + place - 1]`. */
  readonly kindPages: i32[]
  readonly kindCounts: i32[]
  readonly kindPageN: i32[]
  readonly kindCountN: i32[]
  private readonly pageTable: i32[]
  private readonly countTable: i32[]
  /** Whether the key tables hold this plan's keys. */
  private keyed: boolean = false
  /** Group A's answers: each page's ids and authors (a window of `ids` and `authors`), and each count. */
  readonly pageStart: i32[]
  readonly pageLen: i32[]
  readonly countValue: i64[]
  globalCount: i64 = 0
  ids: i64[]
  authors: i64[]
  idEnd: i32 = 0
  /** The distinct articles group B reads, an open-addressed table of `metaIds` places plus one, and which need a body. */
  metaIds: i64[]
  /** Each of `metaIds`' favorite count, from the worker's count lane. */
  metaCount: i64[]
  metaSlot: i32[]
  metaFull: boolean[]
  metas: i32 = 0
  private readonly idTable: i32[]
  /** Each article's JSON in `text`: [m0, m1) up to the body, [m1, m2) the body, [m2, m3) up to `favorited`, [m3, m4) up to `following`. */
  m0: i32[]
  m1: i32[]
  m2: i32[]
  m3: i32[]
  m4: i32[]
  found: boolean[]
  text: u8[]
  textEnd: i32 = 0
  /** The flags group B found true: (viewer, id) pairs, `kind` 0 favorited and 1 following, in an open-addressed table. */
  private flagV: i64[]
  private flagId: i64[]
  private flagKind: i32[]
  private flagSlot: i32[]
  private readonly flagTable: i32[]
  flags: i32 = 0
  /** The pairs group B asks about: favorited (viewer, article) and following (viewer, author). */
  askV: i64[]
  askId: i64[]
  askKind: i32[]
  askSlot: i32[]
  asks: i32 = 0
  /**
   * Each ask's viewer, as its place in `flagViewers` (the plan's distinct
   * signed-in viewers); the place `ask` records; and the asks grouped by
   * viewer and kind for `bindB` (`askOrder`, bucket `2 * place + kind`
   * starting at `askStart[bucket]`), and the text of one viewer's ids.
   */
  askVi: i32[]
  flagViewers: i64[]
  flagViewerN: i32 = 0
  private curVi: i32 = 0
  private askOrder: i32[]
  private askStart: i32[]
  private flagText: u8[]
  private readonly askTable: i32[]
  /** Group A's statements in the order bound, and how many have completed; whether a statement failed. */
  readonly stmts: i32[]
  stmtCount: i32 = 0
  stmtDone: i32 = 0
  failed: boolean = false
  /** `tagRanks`'s walk over a row's tag ids, on a decoder of its own so a refused array leaves the connection's `binary.failed` alone. */
  private readonly tagWalk: PgBinaryArray
  /** The batchers of articles and comments by slug, each distinct slug one key, `tag` its first request; and their runs. */
  articles: PgBatcher
  comments: PgBatcher
  profiles: PgBatcher
  articleRun: i32 = -1
  commentRun: i32 = -1
  profileRun: i32 = -1
  articleEnded: boolean = false
  commentEnded: boolean = false
  profileEnded: boolean = false
  /**
   * Each request by slug: its article's id and author, or its comments' window of `cStart`.. and whether its article exists.
   * A profile by username uses `slugId` for the user's id and `slugFound`.
   */
  readonly slugId: i64[]
  readonly slugAuthor: i64[]
  readonly slugFound: boolean[]
  /** Comments by slug key (the key's first request): each comment's JSON in `text`, [c0, c1) up to `following`, and its author. */
  commentFirst: i32[]
  commentCount: i32[]
  c0: i32[]
  c1: i32[]
  cAuthor: i64[]
  commentsN: i32 = 0
  /** Each profile key's JSON in `text`, `{"profile":{...,"following":`, as [pStart, pEnd). */
  readonly pStart: i32[]
  readonly pEnd: i32[]
  /**
   * Every tag, read once by the plan in name order: each id's rank in that
   * order (`tagRank`, valid where `tagStamp` is this plan's `gen`), each
   * rank's name (a window of `names`), and the tag list's answer.
   */
  tagRank: i32[]
  tagStamp: i32[]
  gen: i32 = 0
  tagN: i32 = 0
  nameStart: i32[]
  nameLen: i32[]
  names: u8[]
  namesEnd: i32 = 0
  tagsJson: u8[]
  tagsJsonEnd: i32 = 0
  private ranks: i32[]
  /** The answer `render` writes. */
  out: u8[]
  outEnd: i32 = 0
  /** Fixed text. */
  private readonly f: u8[][]
  private readonly stamp: u8[]
  private readonly trueBytes: u8[]
  private readonly falseBytes: u8[]

  constructor() {
    this.tags = new Array<i32>(PLAN_MAX)
    this.kinds = new Array<i32>(PLAN_MAX)
    this.viewers = new Array<i64>(PLAN_MAX)
    this.limits = new Array<i64>(PLAN_MAX)
    this.offsets = new Array<i64>(PLAN_MAX)
    this.keyStarts = new Array<i32>(PLAN_MAX)
    this.keyLens = new Array<i32>(PLAN_MAX)
    this.pageOf = new Array<i32>(PLAN_MAX)
    this.countOf = new Array<i32>(PLAN_MAX)
    this.keys = new Array<u8>(PLAN_KEY_BYTES)
    this.pageRep = new Array<i32>(PLAN_MAX)
    this.pagePlace = new Array<i32>(PLAN_MAX)
    this.countRep = new Array<i32>(PLAN_MAX)
    this.countPlace = new Array<i32>(PLAN_MAX)
    this.kindPages = new Array<i32>(KINDS * PLAN_MAX)
    this.kindCounts = new Array<i32>(KINDS * PLAN_MAX)
    this.kindPageN = new Array<i32>(KINDS)
    this.kindCountN = new Array<i32>(KINDS)
    this.pageTable = new Array<i32>(TABLE)
    this.countTable = new Array<i32>(TABLE)
    this.pageStart = new Array<i32>(PLAN_MAX)
    this.pageLen = new Array<i32>(PLAN_MAX)
    this.countValue = new Array<i64>(PLAN_MAX)
    this.ids = new Array<i64>(4096)
    this.authors = new Array<i64>(4096)
    this.metaIds = new Array<i64>(4096)
    this.metaCount = new Array<i64>(4096)
    this.metaSlot = new Array<i32>(4096)
    this.metaFull = new Array<boolean>(4096)
    this.idTable = new Array<i32>(ID_TABLE)
    this.m0 = new Array<i32>(4096)
    this.m1 = new Array<i32>(4096)
    this.m2 = new Array<i32>(4096)
    this.m3 = new Array<i32>(4096)
    this.m4 = new Array<i32>(4096)
    this.found = new Array<boolean>(4096)
    this.text = new Array<u8>(262144)
    this.flagV = new Array<i64>(4096)
    this.flagId = new Array<i64>(4096)
    this.flagKind = new Array<i32>(4096)
    this.flagSlot = new Array<i32>(4096)
    this.flagTable = new Array<i32>(ID_TABLE)
    this.askV = new Array<i64>(4096)
    this.askId = new Array<i64>(4096)
    this.askKind = new Array<i32>(4096)
    this.askSlot = new Array<i32>(4096)
    this.askVi = new Array<i32>(4096)
    this.flagViewers = new Array<i64>(PLAN_MAX)
    this.askOrder = new Array<i32>(4096)
    this.askStart = new Array<i32>(2 * PLAN_MAX + 1)
    this.flagText = new Array<u8>(4096)
    this.askTable = new Array<i32>(ID_TABLE)
    this.stmts = new Array<i32>(KINDS)
    this.tagWalk = new PgBinaryArray(new PgBinary())
    this.articles = new PgBatcher(planArticleBatch(PLAN_MAX))
    this.comments = new PgBatcher(planCommentBatch(PLAN_MAX))
    this.profiles = new PgBatcher(planProfileBatch(PLAN_MAX))
    this.pStart = new Array<i32>(PLAN_MAX)
    this.pEnd = new Array<i32>(PLAN_MAX)
    this.slugId = new Array<i64>(PLAN_MAX)
    this.slugAuthor = new Array<i64>(PLAN_MAX)
    this.slugFound = new Array<boolean>(PLAN_MAX)
    this.commentFirst = new Array<i32>(PLAN_MAX)
    this.commentCount = new Array<i32>(PLAN_MAX)
    this.c0 = new Array<i32>(4096)
    this.c1 = new Array<i32>(4096)
    this.cAuthor = new Array<i64>(4096)
    this.out = new Array<u8>(65536)
    this.tagRank = new Array<i32>(1024)
    this.tagStamp = new Array<i32>(1024)
    this.nameStart = new Array<i32>(1024)
    this.nameLen = new Array<i32>(1024)
    this.names = new Array<u8>(16384)
    this.tagsJson = new Array<u8>(16384)
    this.ranks = new Array<i32>(64)
    this.f = [
      planBytes('{"slug":'),
      planBytes(',"title":'),
      planBytes(',"description":'),
      planBytes(',"body":'),
      planBytes(',"tagList":'),
      planBytes(',"createdAt":"'),
      planBytes('","updatedAt":"'),
      planBytes('","favorited":'),
      planBytes(',"favoritesCount":'),
      planBytes(',"author":{"username":'),
      planBytes(',"bio":'),
      planBytes(',"image":'),
      planBytes(',"following":'),
      planBytes("}}"),
      planBytes('{"articles":['),
      planBytes('],"articlesCount":'),
      planBytes('{"article":'),
      planBytes('{"comments":['),
      planBytes("]}"),
      planBytes('{"id":'),
      planBytes(',"createdAt":"'),
      planBytes('","updatedAt":"'),
      planBytes('","body":'),
      planBytes('{"tags":['),
      planBytes('{"profile":{"username":'),
    ]
    this.stamp = new Array<u8>(32)
    this.trueBytes = planBytes("t")
    this.falseBytes = planBytes("f")
  }

  /** Empties the plan for its next requests. */
  reset(): void {
    this.keyEnd = 0
    this.pages = 0
    this.counts = 0
    for (let k: i32 = 0; k < KINDS; k++) {
      this.kindPageN[k] = 0
      this.kindCountN[k] = 0
    }
    this.clearKeyTables()
    this.count = 0
    this.idEnd = 0
    // Each table entry is cleared at the slot it was put in.
    for (let k: i32 = 0; k < this.metas && k < toI32(this.metaSlot.length); k++) {
      this.idTable[this.metaSlot[k]] = 0
    }
    this.metas = 0
    this.textEnd = 0
    for (let k: i32 = 0; k < this.flags && k < toI32(this.flagSlot.length); k++) {
      this.flagTable[this.flagSlot[k]] = 0
    }
    this.flags = 0
    for (let k: i32 = 0; k < this.asks && k < toI32(this.askSlot.length); k++) {
      this.askTable[this.askSlot[k]] = 0
    }
    this.asks = 0
    this.stmtCount = 0
    this.stmtDone = 0
    this.failed = false
    this.articleRun = -1
    this.commentRun = -1
    this.profileRun = -1
    this.articleEnded = false
    this.commentEnded = false
    this.profileEnded = false
    this.commentsN = 0
    this.gen = this.gen === 2147483647 ? 1 : this.gen + 1
    this.tagN = 0
    this.namesEnd = 0
    this.tagsJsonEnd = 0
  }

  // ---- Requests and their keys ----------------------------------------------------

  /**
   * Adds a request of `kind` with its tag, viewer, limit, offset and key
   * `src[start, start + len)` (a tag, a username or a slug; -1 long for
   * none); false, and nothing added, when the plan is full.
   */
  add(tag: i32, kind: i32, viewer: i64, limit: i64, offset: i64, src: u8[], start: i32, len: i32): boolean {
    const n: i32 = len > 0 ? len : 0
    if (this.count >= PLAN_MAX || this.keyEnd + n > PLAN_KEY_BYTES || (!this.keyed && this.count > 0)) {
      return false
    }
    this.keyed = true
    const i: i32 = this.count
    this.tags[i] = tag
    this.kinds[i] = kind
    this.viewers[i] = viewer
    this.limits[i] = limit
    this.offsets[i] = offset
    this.keyStarts[i] = this.keyEnd
    this.keyLens[i] = n
    copyBytes(this.keys, this.keyEnd, src, start, n)
    this.keyEnd += n
    this.count = i + 1
    this.pageOf[i] = -1
    this.countOf[i] = -1
    if (kind === K_TAGS) {
      this.kindPageN[K_TAGS] += 1
    } else if (kind < LIST_KINDS) {
      this.pageOf[i] = this.keyOf(i, true)
      if (kind !== K_GLOBAL) {
        this.countOf[i] = this.keyOf(i, false)
      }
    } else {
      // An article, comments or a profile: one key a slug or a username, the request that stands for it.
      this.pageOf[i] = this.keyOf(i, true)
    }
    return true
  }

  /** Whether requests `a` and `b` have the same key bytes. */
  private sameKey(a: i32, b: i32): boolean {
    const n: i32 = this.keyLens[a]
    if (n !== this.keyLens[b]) {
      return false
    }
    const x: i32 = this.keyStarts[a]
    const y: i32 = this.keyStarts[b]
    for (let k: i32 = 0; k < n; k++) {
      if (this.keys[x + k] !== this.keys[y + k]) {
        return false
      }
    }
    return true
  }

  /** Whether `a` and `b` read the same page (`page`) or the same count. */
  private same(a: i32, b: i32, page: boolean): boolean {
    const kind: i32 = this.kinds[a]
    if (kind !== this.kinds[b]) {
      return false
    }
    if (
      page &&
      kind < LIST_KINDS &&
      (this.limits[a] !== this.limits[b] || this.offsets[a] !== this.offsets[b])
    ) {
      return false
    }
    if (kind === K_FEED) {
      return this.viewers[a] === this.viewers[b]
    }
    return kind === K_GLOBAL || this.sameKey(a, b)
  }

  private hashOf(i: i32, page: boolean): i32 {
    const kind: i32 = this.kinds[i]
    let h: u32 = hashInt(fnv(), toI64(kind))
    if (page && kind < LIST_KINDS) {
      h = hashInt(hashInt(h, this.limits[i]), this.offsets[i])
    }
    if (kind === K_FEED) {
      h = hashInt(h, this.viewers[i])
    } else if (kind !== K_GLOBAL) {
      const s: i32 = this.keyStarts[i]
      for (let k: i32 = 0; k < this.keyLens[i]; k++) {
        h = (h ^ toU32(toI32(this.keys[s + k]))) * 16777619
      }
    }
    return slotOf(h)
  }

  /** The page key (`page`) or count key request `i` reads, made when it is the first. */
  private keyOf(i: i32, page: boolean): i32 {
    const table: i32[] = page ? this.pageTable : this.countTable
    const mask: i32 = TABLE - 1
    let slot: i32 = this.hashOf(i, page) & mask
    while (table[slot] > 0) {
      const key: i32 = table[slot] - 1
      if (this.same(page ? this.pageRep[key] : this.countRep[key], i, page)) {
        return key
      }
      slot = (slot + 1) & mask
    }
    const kind: i32 = this.kinds[i]
    if (page) {
      const key: i32 = this.pages
      this.pages = key + 1
      table[slot] = key + 1
      this.pageRep[key] = i
      const place: i32 = this.kindPageN[kind]
      this.kindPageN[kind] = place + 1
      this.kindPages[kind * PLAN_MAX + place] = key
      this.pagePlace[key] = place + 1
      this.pageLen[key] = 0
      this.pageStart[key] = 0
      this.slugFound[key] = false
      this.commentCount[key] = -1
      return key
    }
    const key: i32 = this.counts
    this.counts = key + 1
    table[slot] = key + 1
    this.countRep[key] = i
    const place: i32 = this.kindCountN[kind]
    this.kindCountN[kind] = place + 1
    this.kindCounts[kind * PLAN_MAX + place] = key
    this.countPlace[key] = place + 1
    this.countValue[key] = 0
    return key
  }

  /** Empties the key tables once the requests are in (group A binds from the lists), or for the next plan. */
  private clearKeyTables(): void {
    if (!this.keyed) {
      return
    }
    this.keyed = false
    for (let k: i32 = 0; k < this.count; k++) {
      if (this.pageOf[k] < 0) {
        continue
      }
      // Each request's keys were made at its own hash, or probed past it: clear the run.
      this.clearRun(this.pageTable, this.hashOf(k, true))
      if (this.countOf[k] >= 0) {
        this.clearRun(this.countTable, this.hashOf(k, false))
      }
    }
  }

  private clearRun(table: i32[], h: i32): void {
    const mask: i32 = TABLE - 1
    let slot: i32 = h & mask
    while (table[slot] !== 0) {
      table[slot] = 0
      slot = (slot + 1) & mask
    }
  }

  // ---- Group A --------------------------------------------------------------------

  /** Binds group A on `conn`; false when a builder call refused (the plan is then failed). */
  bindA(conn: PgConnection): boolean {
    this.clearKeyTables()
    // Every tag by name: the tag list's answer, and the names of every article's tags.
    let named: boolean = this.kindPageN[K_TAGS] > 0 || this.kindPageN[K_ARTICLE] > 0
    for (let kind: i32 = 0; kind < LIST_KINDS; kind++) {
      named = named || this.kindPageN[kind] > 0
    }
    if (named) {
      if (!conn.bindStart("plan_tags") || !conn.bindEnd()) {
        return false
      }
      this.stmts[this.stmtCount] = K_TAGS
      this.stmtCount += 1
    }
    for (let kind: i32 = 0; kind < LIST_KINDS; kind++) {
      if (this.kindPageN[kind] === 0) {
        continue
      }
      if (!this.bindList(conn, kind)) {
        return false
      }
      this.stmts[this.stmtCount] = kind
      this.stmtCount += 1
    }
    if (this.kindPageN[K_ARTICLE] > 0) {
      this.articleRun = this.takeSlugs(conn, this.articles, K_ARTICLE)
      if (this.articleRun < 0) {
        return false
      }
      this.stmts[this.stmtCount] = K_ARTICLE
      this.stmtCount += 1
    }
    if (this.kindPageN[K_COMMENTS] > 0) {
      this.commentRun = this.takeSlugs(conn, this.comments, K_COMMENTS)
      if (this.commentRun < 0) {
        return false
      }
      this.stmts[this.stmtCount] = K_COMMENTS
      this.stmtCount += 1
    }
    if (this.kindPageN[K_PROFILE] > 0) {
      this.profileRun = this.takeSlugs(conn, this.profiles, K_PROFILE)
      if (this.profileRun < 0) {
        return false
      }
      this.stmts[this.stmtCount] = K_PROFILE
      this.stmtCount += 1
    }
    return true
  }

  /** The batcher of `kind`: articles, comments or profiles. */
  private batcher(kind: i32): PgBatcher {
    return kind === K_ARTICLE ? this.articles : kind === K_COMMENTS ? this.comments : this.profiles
  }

  private runOf(kind: i32): i32 {
    return kind === K_ARTICLE ? this.articleRun : kind === K_COMMENTS ? this.commentRun : this.profileRun
  }

  private endedOf(kind: i32): boolean {
    return kind === K_ARTICLE ? this.articleEnded : kind === K_COMMENTS ? this.commentEnded : this.profileEnded
  }

  private setEnded(kind: i32): void {
    if (kind === K_ARTICLE) {
      this.articleEnded = true
    } else if (kind === K_COMMENTS) {
      this.commentEnded = true
    } else {
      this.profileEnded = true
    }
  }

  /** Queues each distinct slug of `kind` in `b`, tagged with its key, and binds them all as one execution. */
  private takeSlugs(conn: PgConnection, b: PgBatcher, kind: i32): i32 {
    const n: i32 = this.kindPageN[kind]
    for (let p: i32 = 0; p < n; p++) {
      const key: i32 = this.kindPages[kind * PLAN_MAX + p]
      const i: i32 = this.pageRep[key]
      if (!b.addText(this.keys, this.keyStarts[i], this.keyLens[i], key)) {
        return -1
      }
    }
    const run: i32 = b.take(conn)
    // Every key must be in this execution: one left queued would join another
    // plan's. A batcher left with keys (the connection refused the bind for
    // room) is made again, empty.
    if (run < 0 || b.waiting() > 0) {
      if (kind === K_ARTICLE) {
        this.articles = new PgBatcher(planArticleBatch(PLAN_MAX))
      } else if (kind === K_COMMENTS) {
        this.comments = new PgBatcher(planCommentBatch(PLAN_MAX))
      } else {
        this.profiles = new PgBatcher(planProfileBatch(PLAN_MAX))
      }
      return -1
    }
    return run
  }

  /**
   * Ends the slug reads group A left open when the group failed or its
   * connection was lost, so that their batchers' runs are free for the next
   * plan.
   */
  abortA(): void {
    this.failed = true
    if (this.articleRun >= 0 && !this.articleEnded) {
      this.slugFinish(K_ARTICLE)
    }
    if (this.commentRun >= 0 && !this.commentEnded) {
      this.slugFinish(K_COMMENTS)
    }
    if (this.profileRun >= 0 && !this.profileEnded) {
      this.slugFinish(K_PROFILE)
    }
  }

  private slugFinish(kind: i32): void {
    const b: PgBatcher = this.batcher(kind)
    const run: i32 = this.runOf(kind)
    b.fail(run)
    while (b.next(run) !== PG_BATCH_NONE) {}
    this.setEnded(kind)
  }

  /** Binds `kind`'s list statement: its count keys, then its page keys. */
  private bindList(conn: PgConnection, kind: i32): boolean {
    if (!conn.bindStart(listStatement(kind))) {
      return false
    }
    const pages: i32 = this.kindPageN[kind]
    const counts: i32 = this.kindCountN[kind]
    if (kind !== K_GLOBAL) {
      // The count keys: a viewer, or a tag or username.
      if (!conn.arrayStart()) {
        return false
      }
      for (let c: i32 = 0; c < counts; c++) {
        const i: i32 = this.countRep[this.kindCounts[kind * PLAN_MAX + c]]
        if (!this.keyElement(conn, kind, i)) {
          conn.arrayEnd()
          return false
        }
      }
      conn.arrayEnd()
      // The page keys' viewers, tags or usernames.
      if (!conn.arrayStart()) {
        return false
      }
      for (let p: i32 = 0; p < pages; p++) {
        const i: i32 = this.pageRep[this.kindPages[kind * PLAN_MAX + p]]
        if (!this.keyElement(conn, kind, i)) {
          conn.arrayEnd()
          return false
        }
      }
      conn.arrayEnd()
    }
    // Their limits, then their offsets.
    for (let half: i32 = 0; half < 2; half++) {
      if (!conn.arrayStart()) {
        return false
      }
      for (let p: i32 = 0; p < pages; p++) {
        const i: i32 = this.pageRep[this.kindPages[kind * PLAN_MAX + p]]
        if (!conn.arrayInt(half === 0 ? this.limits[i] : this.offsets[i])) {
          conn.arrayEnd()
          return false
        }
      }
      conn.arrayEnd()
    }
    return conn.bindEnd()
  }

  private keyElement(conn: PgConnection, kind: i32, i: i32): boolean {
    if (kind === K_FEED) {
      return conn.arrayInt(this.viewers[i])
    }
    return conn.arrayElement(this.keys, this.keyStarts[i], this.keyLens[i])
  }

  /** One event of group A. */
  eventA(conn: PgConnection, event: i32): void {
    if (this.stmtDone >= this.stmtCount) {
      return
    }
    const s: i32 = this.stmts[this.stmtDone]
    if (s === K_ARTICLE || s === K_COMMENTS || s === K_PROFILE) {
      this.slugEvent(conn, event, s)
    } else if (s === K_TAGS) {
      if (event === PG_ROW) {
        this.tagRow(conn)
      } else if (event === PG_COMPLETE) {
        this.tagsDone()
      }
    } else if (event === PG_ROW) {
      this.listRow(conn, s)
    }
    if (event === PG_COMPLETE) {
      this.stmtDone += 1
    } else if (event === PG_ERROR) {
      this.failed = true
      this.stmtDone = this.stmtCount
    }
  }

  /** A tag, (id, name), the next in name order. */
  private tagRow(conn: PgConnection): void {
    const id: i64 = conn.int(0)
    if (id < 0 || id >= toI64(TAG_ID_MAX) || conn.isNull(1)) {
      this.failed = true
      return
    }
    const t: i32 = toI32(id)
    if (t >= toI32(this.tagRank.length)) {
      let size: i32 = toI32(this.tagRank.length) * 2
      while (size <= t) {
        size = size * 2
      }
      const rank: i32[] = new Array<i32>(size)
      const stamp: i32[] = new Array<i32>(size)
      for (let k: i32 = 0; k < toI32(this.tagRank.length) && k < size; k++) {
        rank[k] = this.tagRank[k]
        stamp[k] = this.tagStamp[k]
      }
      this.tagRank = rank
      this.tagStamp = stamp
    }
    const r: i32 = this.tagN
    this.nameStart = grownI32(this.nameStart, r + 1, r)
    this.nameLen = grownI32(this.nameLen, r + 1, r)
    const len: i32 = conn.colLength(1)
    this.names = grownBytes(this.names, this.namesEnd + len, this.namesEnd)
    copyBytes(this.names, this.namesEnd, conn.inputBuffer(), conn.colStart(1), len)
    this.nameStart[r] = this.namesEnd
    this.nameLen[r] = len
    this.namesEnd += len
    if (t < toI32(this.tagRank.length)) {
      this.tagRank[t] = r
      this.tagStamp[t] = this.gen
    }
    this.tagN = r + 1
  }

  /** Every tag has come: the tag list's answer, `{"tags":[...]}`. */
  private tagsDone(): void {
    let worst: i32 = 32
    for (let r: i32 = 0; r < this.tagN; r++) {
      worst += jsonOutWorst(this.nameLen[r]) + 1
    }
    this.tagsJson = grownBytes(this.tagsJson, worst, 0)
    const out: u8[] = this.tagsJson
    let o: i32 = jsonOutRaw(out, 0, this.f[23])
    for (let r: i32 = 0; r < this.tagN; r++) {
      if (r > 0) {
        out[o] = toU8(44)
        o++
      }
      o = jsonOutString(out, o, this.names, this.nameStart[r], this.nameLen[r])
    }
    this.tagsJsonEnd = jsonOutRaw(out, o, this.f[18])
  }

  /** A list statement's row: (k, count, ids, authors), a count row when k <= 0 and a page row when k > 0. */
  private listRow(conn: PgConnection, kind: i32): void {
    const k: i64 = conn.int(0)
    if (k <= 0) {
      if (kind === K_GLOBAL) {
        // The one count every global page shares.
        this.globalCount = conn.int(1)
        return
      }
      const place: i32 = toI32(-k)
      if (place >= 1 && place <= this.kindCountN[kind]) {
        this.countValue[this.kindCounts[kind * PLAN_MAX + place - 1]] = conn.int(1)
      } else {
        this.failed = true
      }
      return
    }
    if (k > toI64(this.kindPageN[kind])) {
      this.failed = true
      return
    }
    const key: i32 = this.kindPages[kind * PLAN_MAX + toI32(k) - 1]
    const start: i32 = this.idEnd
    const n: i32 = this.readInts(conn, 2, start, false)
    const m: i32 = this.readInts(conn, 3, start, true)
    if (n < 0 || m !== n) {
      this.failed = true
      return
    }
    this.idEnd = start + n
    this.pageStart[key] = start
    this.pageLen[key] = n
    for (let j: i32 = 0; j < n; j++) {
      this.addMeta(this.ids[start + j], false)
    }
  }

  /**
   * Reads the `int8[]` column `c` (NULL is empty) to `ids`, or `authors`,
   * from `base` on; answers how many, -1 when it is not one.
   */
  private readInts(conn: PgConnection, c: i32, base: i32, authors: boolean): i32 {
    if (conn.isNull(c)) {
      return 0
    }
    const b: u8[] = conn.inputBuffer()
    const start: i32 = conn.colStart(c)
    const end: i32 = start + conn.colLength(c)
    if (end - start < 2 || b[start] !== toU8(123) || b[end - 1] !== toU8(125)) {
      return -1
    }
    let n: i32 = 0
    let at: i32 = start + 1
    while (at < end - 1) {
      let v: i64 = 0
      let digits: i32 = 0
      while (at < end - 1 && b[at] >= toU8(48) && b[at] <= toU8(57)) {
        v = v * 10 + toI64(toI32(b[at]) - 48)
        digits++
        at++
      }
      if (digits === 0 || digits > 18) {
        return -1
      }
      if (authors) {
        this.authors = grownInts(this.authors, base + n + 1, base + n)
        this.authors[base + n] = v
      } else {
        this.ids = grownInts(this.ids, base + n + 1, base + n)
        this.ids[base + n] = v
      }
      n++
      if (at < end - 1) {
        if (b[at] !== toU8(44)) {
          return -1
        }
        at++
      }
    }
    return n
  }

  /** One event of a batched read by slug or username, articles, comments or profiles: each row and end goes to its key. */
  private slugEvent(conn: PgConnection, event: i32, kind: i32): void {
    const b: PgBatcher = this.batcher(kind)
    const run: i32 = this.runOf(kind)
    if (this.endedOf(kind) || run < 0) {
      return
    }
    if (event === PG_ROW) {
      b.row(run, conn)
    } else if (event === PG_COMPLETE || event === PG_ERROR) {
      if (event === PG_COMPLETE) {
        b.end(run)
      } else {
        b.fail(run)
      }
      this.setEnded(kind)
    } else {
      return
    }
    let e: i32 = b.next(run)
    while (e !== PG_BATCH_NONE) {
      const key: i32 = b.tag
      if (e === PG_BATCH_ROW) {
        if (kind === K_ARTICLE) {
          this.slugId[key] = conn.binaryInt(0)
          this.slugAuthor[key] = conn.binaryInt(1)
          this.slugFound[key] = true
        } else if (kind === K_PROFILE) {
          this.profileRow(conn, key)
        } else {
          this.commentRow(conn, key)
        }
      } else if (e === PG_BATCH_MISSING) {
        this.slugFound[key] = false
        this.commentCount[key] = 0
      } else if (e !== PG_BATCH_DONE) {
        this.failed = true
      }
      e = b.next(run)
    }
  }

  /** A comments row of slug key `key`: its article exists, and the comment, when there is one, is written up to `following`. */
  private commentRow(conn: PgConnection, key: i32): void {
    if (this.commentCount[key] < 0) {
      this.slugFound[key] = true
      this.commentFirst[key] = this.commentsN
      this.commentCount[key] = 0
    }
    if (conn.isNull(C_ID)) {
      return
    }
    const c: i32 = this.commentsN
    this.c0 = grownI32(this.c0, c + 1, c)
    this.c1 = grownI32(this.c1, c + 1, c)
    this.cAuthor = grownInts(this.cAuthor, c + 1, c)
    let worst: i32 = 256
    for (let col: i32 = C_BODY; col <= C_IMAGE; col++) {
      worst += jsonOutWorst(conn.colLength(col) > 0 ? conn.colLength(col) : 0)
    }
    this.text = grownBytes(this.text, this.textEnd + worst, this.textEnd)
    const out: u8[] = this.text
    const b: u8[] = conn.inputBuffer()
    const f: u8[][] = this.f
    let o: i32 = this.textEnd
    this.c0[c] = o
    o = jsonOutRaw(out, o, f[19])
    o = jwtDigits(conn.binaryInt(C_ID), out, o)
    o = jsonOutRaw(out, o, f[20])
    o = this.stampInto(out, o, conn, C_CREATED)
    o = jsonOutRaw(out, o, f[21])
    o = this.stampInto(out, o, conn, C_UPDATED)
    o = jsonOutRaw(out, o, f[22])
    o = this.stringOrNull(out, o, conn, b, C_BODY)
    o = jsonOutRaw(out, o, f[9])
    o = this.stringOrNull(out, o, conn, b, C_USERNAME)
    o = jsonOutRaw(out, o, f[10])
    o = this.stringOrNull(out, o, conn, b, C_BIO)
    o = jsonOutRaw(out, o, f[11])
    o = this.stringOrNull(out, o, conn, b, C_IMAGE)
    o = jsonOutRaw(out, o, f[12])
    this.c1[c] = o
    this.textEnd = o
    this.cAuthor[c] = conn.binaryInt(C_AUTHOR)
    this.commentsN = c + 1
    this.commentCount[key] += 1
  }

  /** A profile row of username key `key`: the user's id, and its answer written up to `following`. */
  private profileRow(conn: PgConnection, key: i32): void {
    if (conn.isNull(P_USERNAME)) {
      this.failed = true
      return
    }
    let worst: i32 = 128
    for (let col: i32 = P_USERNAME; col <= P_IMAGE; col++) {
      worst += jsonOutWorst(conn.colLength(col) > 0 ? conn.colLength(col) : 0)
    }
    this.text = grownBytes(this.text, this.textEnd + worst, this.textEnd)
    const out: u8[] = this.text
    const b: u8[] = conn.inputBuffer()
    const f: u8[][] = this.f
    let o: i32 = this.textEnd
    this.pStart[key] = o
    o = jsonOutRaw(out, o, f[24])
    o = jsonOutString(out, o, b, conn.colStart(P_USERNAME), conn.colLength(P_USERNAME))
    o = jsonOutRaw(out, o, f[10])
    o = this.stringOrNull(out, o, conn, b, P_BIO)
    o = jsonOutRaw(out, o, f[11])
    o = this.stringOrNull(out, o, conn, b, P_IMAGE)
    o = jsonOutRaw(out, o, f[12])
    this.pEnd[key] = o
    this.textEnd = o
    this.slugId[key] = conn.binaryInt(P_ID)
    this.slugFound[key] = true
  }

  /**
   * Reads the `plan_meta` row's tag ids, a binary `int4[]`, to `ranks` as
   * their ranks in name order, sorted; answers how many, or -1 when one is
   * not a tag the plan read (or the column is not that array).
   */
  private tagRanks(conn: PgConnection): i32 {
    if (conn.isNull(M_TAGS)) {
      return 0
    }
    const walk: PgBinaryArray = this.tagWalk
    walk.begin(conn.inputBuffer(), conn.colStart(M_TAGS), conn.colLength(M_TAGS))
    let n: i32 = 0
    let next: i32 = walk.next()
    while (next === PG_ARRAY_ELEMENT) {
      const id: i64 = walk.int()
      if (id < 0 || id >= toI64(this.tagRank.length)) {
        return -1
      }
      const v: i32 = toI32(id)
      if (this.tagStamp[v] !== this.gen) {
        return -1
      }
      this.ranks = grownI32(this.ranks, n + 1, n)
      // Inserted in order: an article has a few tags.
      const r: i32 = this.tagRank[v]
      let k: i32 = n
      while (k > 0 && this.ranks[k - 1] > r) {
        this.ranks[k] = this.ranks[k - 1]
        k--
      }
      this.ranks[k] = r
      n++
      next = walk.next()
    }
    return next === PG_ARRAY_END ? n : -1
  }

  private stringOrNull(out: u8[], o: i32, conn: PgConnection, b: u8[], c: i32): i32 {
    return conn.isNull(c)
      ? jsonOutNull(out, o)
      : jsonOutString(out, o, b, conn.colStart(c), conn.colLength(c))
  }

  /** A binary row's `timestamptz` column `c` as RFC 3339 with milliseconds (no quotes), or `failed` when it does not read. */
  private stampInto(out: u8[], o: i32, conn: PgConnection, c: i32): i32 {
    const n: i32 = conn.binary.timestamp(conn.inputBuffer(), conn.colStart(c), conn.colLength(c), this.stamp, 0)
    if (n < 0) {
      this.failed = true
      return o
    }
    copyBytes(out, o, this.stamp, 0, n)
    return o + n
  }

  /** After group A: queues the articles of slug reads, and the flags every viewer needs; whether group B has anything to read. */
  planB(): boolean {
    this.flagViewerN = 0
    for (let i: i32 = 0; i < this.count; i++) {
      const kind: i32 = this.kinds[i]
      const v: i64 = this.viewers[i]
      if (v !== 0) {
        // The viewer's place among the plan's distinct viewers, at most PLAN_MAX of them.
        let vi: i32 = 0
        while (vi < this.flagViewerN && this.flagViewers[vi] !== v) {
          vi++
        }
        if (vi === this.flagViewerN) {
          this.flagViewers[vi] = v
          this.flagViewerN = vi + 1
        }
        this.curVi = vi
      }
      if (kind === K_ARTICLE) {
        const key: i32 = this.pageOf[i]
        if (this.slugFound[key]) {
          this.addMeta(this.slugId[key], true)
          if (v !== 0) {
            this.ask(v, this.slugId[key], 0)
            this.ask(v, this.slugAuthor[key], 1)
          }
        }
      } else if (kind === K_PROFILE) {
        const key: i32 = this.pageOf[i]
        if (v !== 0 && this.slugFound[key]) {
          this.ask(v, this.slugId[key], 1)
        }
      } else if (kind === K_COMMENTS) {
        const key: i32 = this.pageOf[i]
        if (v !== 0 && this.slugFound[key]) {
          const first: i32 = this.commentFirst[key]
          for (let c: i32 = first; c < first + this.commentCount[key]; c++) {
            this.ask(v, this.cAuthor[c], 1)
          }
        }
      } else if (v !== 0 && kind < LIST_KINDS) {
        const key: i32 = this.pageOf[i]
        const start: i32 = this.pageStart[key]
        for (let j: i32 = start; j < start + this.pageLen[key]; j++) {
          this.ask(v, this.ids[j], 0)
          this.ask(v, this.authors[j], 1)
        }
      }
    }
    return this.metas > 0 || this.asks > 0
  }

  /** Takes the favorite count of every article of the plan from `run`. */
  takeCounts(run: CountRun): void {
    for (let k: i32 = 0; k < this.metas; k++) {
      this.metaCount[k] = run.count(this.metaIds[k])
    }
  }

  // ---- Group B --------------------------------------------------------------------

  /** Binds group B: the articles, then the flags; false when a builder call refused. */
  bindB(conn: PgConnection): boolean {
    this.stmtCount = 0
    this.stmtDone = 0
    if (this.metas > 0) {
      if (
        !conn.bindStartBinary("plan_meta") ||
        !conn.paramIntArray(this.metaIds, 0, this.metas) ||
        !conn.arrayStart()
      ) {
        return false
      }
      for (let k: i32 = 0; k < this.metas; k++) {
        const v: u8[] = this.metaFull[k] ? this.trueBytes : this.falseBytes
        if (!conn.arrayElement(v, 0, 1)) {
          conn.arrayEnd()
          return false
        }
      }
      conn.arrayEnd()
      if (!conn.bindEnd()) {
        return false
      }
      this.stmts[this.stmtCount] = S_META
      this.stmtCount += 1
    }
    if (this.asks > 0) {
      // The asks by viewer and kind, a counting sort: Postgres then takes
      // each viewer's ids as one array instead of regrouping every pair.
      const buckets: i32 = 2 * this.flagViewerN
      for (let b: i32 = 0; b <= buckets; b++) {
        this.askStart[b] = 0
      }
      for (let k: i32 = 0; k < this.asks; k++) {
        this.askStart[2 * this.askVi[k] + this.askKind[k] + 1] += 1
      }
      for (let b: i32 = 0; b < buckets; b++) {
        this.askStart[b + 1] += this.askStart[b]
      }
      this.askOrder = grownI32(this.askOrder, this.asks, 0)
      for (let k: i32 = 0; k < this.asks; k++) {
        const b: i32 = 2 * this.askVi[k] + this.askKind[k]
        this.askOrder[this.askStart[b]] = k
        this.askStart[b] += 1
      }
      // Each bucket's start moved to its end: walk back one bucket.
      for (let b: i32 = buckets; b > 0; b--) {
        this.askStart[b] = this.askStart[b - 1]
      }
      this.askStart[0] = 0
      if (!conn.bindStart("plan_flags") || !conn.paramIntArray(this.flagViewers, 0, this.flagViewerN)) {
        return false
      }
      for (let kind: i32 = 0; kind < 2; kind++) {
        // Favorited: each viewer's articles; following: each viewer's authors.
        if (!conn.arrayStart()) {
          return false
        }
        for (let vi: i32 = 0; vi < this.flagViewerN; vi++) {
          const b: i32 = 2 * vi + kind
          const n: i32 = this.askStart[b + 1] - this.askStart[b]
          this.flagText = grownBytes(this.flagText, 21 * n + 2, 0)
          const t: u8[] = this.flagText
          let o: i32 = 0
          t[o] = toU8(123)
          o++
          for (let j: i32 = this.askStart[b]; j < this.askStart[b + 1]; j++) {
            if (j > this.askStart[b]) {
              t[o] = toU8(44)
              o++
            }
            o = jwtDigits(this.askId[this.askOrder[j]], t, o)
          }
          t[o] = toU8(125)
          o++
          if (!conn.arrayElement(t, 0, o)) {
            conn.arrayEnd()
            return false
          }
        }
        conn.arrayEnd()
      }
      if (!conn.bindEnd()) {
        return false
      }
      this.stmts[this.stmtCount] = S_FLAGS
      this.stmtCount += 1
    }
    return true
  }

  /** One event of group B. */
  eventB(conn: PgConnection, event: i32): void {
    if (this.stmtDone >= this.stmtCount) {
      return
    }
    if (event === PG_ROW) {
      if (this.stmts[this.stmtDone] === S_META) {
        this.metaRow(conn)
      } else {
        this.flagRow(conn)
      }
    } else if (event === PG_COMPLETE) {
      this.stmtDone += 1
    } else if (event === PG_ERROR) {
      this.failed = true
      this.stmtDone = this.stmtCount
    }
  }

  /** A flags row: (kind, viewer, id), each a pair group B found true. */
  private flagRow(conn: PgConnection): void {
    const kind: i32 = toI32(conn.int(0))
    const v: i64 = conn.int(1)
    const id: i64 = conn.int(2)
    const slot: i32 = this.pairSlot(this.flagTable, this.flagV, this.flagId, this.flagKind, v, id, kind)
    if (this.flagTable[slot] > 0 || this.flags >= ID_TABLE / 2) {
      return
    }
    const k: i32 = this.flags
    this.flagV = grownInts(this.flagV, k + 1, k)
    this.flagId = grownInts(this.flagId, k + 1, k)
    this.flagKind = grownI32(this.flagKind, k + 1, k)
    this.flagSlot = grownI32(this.flagSlot, k + 1, k)
    this.flagSlot[k] = slot
    this.flagV[k] = v
    this.flagId[k] = id
    this.flagKind[k] = kind
    this.flagTable[slot] = k + 1
    this.flags = k + 1
  }

  /** An article row of `plan_meta`: its JSON, cut where the body and the two flags go. */
  private metaRow(conn: PgConnection): void {
    const id: i64 = conn.binaryInt(M_ID)
    const slot: i32 = this.idSlot(id)
    if (this.idTable[slot] === 0) {
      this.failed = true
      return
    }
    const m: i32 = this.idTable[slot] - 1
    // The tags: their ranks in name order, sorted, each a name the plan read.
    const tags: i32 = this.tagRanks(conn)
    if (tags < 0) {
      // A tag the plan's read of every tag did not have (made since): this
      // article's requests go alone.
      return
    }
    let worst: i32 = 512
    for (let k: i32 = 0; k < tags; k++) {
      worst += jsonOutWorst(this.nameLen[this.ranks[k]]) + 1
    }
    for (let c: i32 = M_SLUG; c <= M_BODY; c++) {
      if (c === M_SLUG || c === M_TITLE || c === M_DESCRIPTION || c >= M_USERNAME) {
        worst += jsonOutWorst(conn.colLength(c) > 0 ? conn.colLength(c) : 0)
      }
    }
    this.text = grownBytes(this.text, this.textEnd + worst, this.textEnd)
    const out: u8[] = this.text
    const b: u8[] = conn.inputBuffer()
    const f: u8[][] = this.f
    if (
      conn.isNull(M_SLUG) ||
      conn.isNull(M_TITLE) ||
      conn.isNull(M_DESCRIPTION) ||
      conn.isNull(M_USERNAME)
    ) {
      this.failed = true
      return
    }
    let o: i32 = this.textEnd
    this.m0[m] = o
    o = jsonOutRaw(out, o, f[0])
    o = jsonOutString(out, o, b, conn.colStart(M_SLUG), conn.colLength(M_SLUG))
    o = jsonOutRaw(out, o, f[1])
    o = jsonOutString(out, o, b, conn.colStart(M_TITLE), conn.colLength(M_TITLE))
    o = jsonOutRaw(out, o, f[2])
    o = jsonOutString(out, o, b, conn.colStart(M_DESCRIPTION), conn.colLength(M_DESCRIPTION))
    this.m1[m] = o
    if (!conn.isNull(M_BODY)) {
      o = jsonOutRaw(out, o, f[3])
      o = jsonOutString(out, o, b, conn.colStart(M_BODY), conn.colLength(M_BODY))
    }
    this.m2[m] = o
    o = jsonOutRaw(out, o, f[4])
    out[o] = toU8(91)
    o++
    for (let k: i32 = 0; k < tags; k++) {
      if (k > 0) {
        out[o] = toU8(44)
        o++
      }
      const r: i32 = this.ranks[k]
      o = jsonOutString(out, o, this.names, this.nameStart[r], this.nameLen[r])
    }
    out[o] = toU8(93)
    o = jsonOutRaw(out, o + 1, f[5])
    o = this.stampInto(out, o, conn, M_CREATED)
    o = jsonOutRaw(out, o, f[6])
    o = this.stampInto(out, o, conn, M_UPDATED)
    o = jsonOutRaw(out, o, f[7])
    this.m3[m] = o
    o = jsonOutRaw(out, o, f[8])
    o = jwtDigits(this.metaCount[m], out, o)
    o = jsonOutRaw(out, o, f[9])
    o = jsonOutString(out, o, b, conn.colStart(M_USERNAME), conn.colLength(M_USERNAME))
    o = jsonOutRaw(out, o, f[10])
    o = this.stringOrNull(out, o, conn, b, M_BIO)
    o = jsonOutRaw(out, o, f[11])
    o = this.stringOrNull(out, o, conn, b, M_IMAGE)
    o = jsonOutRaw(out, o, f[12])
    this.m4[m] = o
    this.textEnd = o
    this.found[m] = true
  }

  // ---- Articles and flags by id ---------------------------------------------------

  private idSlot(id: i64): i32 {
    const mask: i32 = ID_TABLE - 1
    let slot: i32 = slotOf(hashInt(fnv(), id)) & mask
    while (this.idTable[slot] > 0 && this.metaIds[this.idTable[slot] - 1] !== id) {
      slot = (slot + 1) & mask
    }
    return slot
  }

  /** Adds article `id` to group B's reads, with its body when `full`. */
  private addMeta(id: i64, full: boolean): void {
    const slot: i32 = this.idSlot(id)
    if (this.idTable[slot] > 0) {
      if (full) {
        this.metaFull[this.idTable[slot] - 1] = true
      }
      return
    }
    if (this.metas >= ID_TABLE / 2) {
      this.failed = true
      return
    }
    const m: i32 = this.metas
    this.growMeta(m + 1)
    this.metaIds[m] = id
    this.metaSlot[m] = slot
    this.metaFull[m] = full
    this.found[m] = false
    this.idTable[slot] = m + 1
    this.metas = m + 1
  }

  private growMeta(n: i32): void {
    if (n <= toI32(this.metaIds.length)) {
      return
    }
    const keep: i32 = this.metas
    this.metaIds = grownInts(this.metaIds, n, keep)
    this.metaCount = grownInts(this.metaCount, n, keep)
    this.metaSlot = grownI32(this.metaSlot, n, keep)
    this.m0 = grownI32(this.m0, n, keep)
    this.m1 = grownI32(this.m1, n, keep)
    this.m2 = grownI32(this.m2, n, keep)
    this.m3 = grownI32(this.m3, n, keep)
    this.m4 = grownI32(this.m4, n, keep)
    const full: boolean[] = new Array<boolean>(toI32(this.metaIds.length))
    const found: boolean[] = new Array<boolean>(toI32(this.metaIds.length))
    for (let k: i32 = 0; k < keep && k < toI32(full.length); k++) {
      full[k] = this.metaFull[k]
      found[k] = this.found[k]
    }
    this.metaFull = full
    this.found = found
  }

  private pairSlot(table: i32[], vs: i64[], ids: i64[], kinds: i32[], v: i64, id: i64, kind: i32): i32 {
    const mask: i32 = ID_TABLE - 1
    let slot: i32 = slotOf(hashInt(hashInt(hashInt(fnv(), v), id), toI64(kind))) & mask
    while (table[slot] > 0) {
      const k: i32 = table[slot] - 1
      if (vs[k] === v && ids[k] === id && kinds[k] === kind) {
        return slot
      }
      slot = (slot + 1) & mask
    }
    return slot
  }

  /** Asks group B whether viewer `v` favorited article `id` (kind 0) or follows user `id` (kind 1), once. */
  private ask(v: i64, id: i64, kind: i32): void {
    const slot: i32 = this.pairSlot(this.askTable, this.askV, this.askId, this.askKind, v, id, kind)
    if (this.askTable[slot] > 0) {
      return
    }
    if (this.asks >= ID_TABLE / 2) {
      this.failed = true
      return
    }
    const k: i32 = this.asks
    this.askV = grownInts(this.askV, k + 1, k)
    this.askId = grownInts(this.askId, k + 1, k)
    this.askKind = grownI32(this.askKind, k + 1, k)
    this.askSlot = grownI32(this.askSlot, k + 1, k)
    this.askVi = grownI32(this.askVi, k + 1, k)
    this.askVi[k] = this.curVi
    this.askSlot[k] = slot
    this.askV[k] = v
    this.askId[k] = id
    this.askKind[k] = kind
    this.askTable[slot] = k + 1
    this.asks = k + 1
  }

  /** Whether group B found viewer `v`'s flag `kind` on `id` true; always false for the anonymous viewer. */
  private flag(v: i64, id: i64, kind: i32): boolean {
    if (v === 0) {
      return false
    }
    return (
      this.flagTable[this.pairSlot(this.flagTable, this.flagV, this.flagId, this.flagKind, v, id, kind)] > 0
    )
  }

  // ---- Answers --------------------------------------------------------------------

  /**
   * Writes request `i`'s answer to `out[0, outEnd)` and answers its status,
   * or `PLAN_ALONE` when the plan cannot answer it: an article group A
   * found that group B did not (deleted in between), or a slug that came
   * back as another.
   */
  render(i: i32): i32 {
    this.outEnd = 0
    const kind: i32 = this.kinds[i]
    const v: i64 = this.viewers[i]
    const key: i32 = this.pageOf[i]
    if (kind === K_TAGS) {
      this.outRoom(this.tagsJsonEnd)
      copyBytes(this.out, 0, this.tagsJson, 0, this.tagsJsonEnd)
      this.outEnd = this.tagsJsonEnd
      return 200
    }
    if (kind === K_PROFILE) {
      if (!this.slugFound[key]) {
        return 404
      }
      const n: i32 = this.pEnd[key] - this.pStart[key]
      this.outRoom(n + 16)
      copyBytes(this.out, 0, this.text, this.pStart[key], n)
      let o: i32 = jsonOutBool(this.out, n, this.flag(v, this.slugId[key], 1))
      o = jsonOutRaw(this.out, o, this.f[13])
      this.outEnd = o
      return 200
    }
    if (kind === K_COMMENTS) {
      if (!this.slugFound[key]) {
        return 404
      }
      const first: i32 = this.commentFirst[key]
      const n: i32 = this.commentCount[key]
      let size: i32 = 64
      for (let c: i32 = first; c < first + n; c++) {
        size += this.c1[c] - this.c0[c] + 16
      }
      this.outRoom(size)
      let o: i32 = jsonOutRaw(this.out, 0, this.f[17])
      for (let c: i32 = first; c < first + n; c++) {
        if (c > first) {
          this.out[o] = toU8(44)
          o++
        }
        copyBytes(this.out, o, this.text, this.c0[c], this.c1[c] - this.c0[c])
        o += this.c1[c] - this.c0[c]
        o = jsonOutBool(this.out, o, this.flag(v, this.cAuthor[c], 1))
        o = jsonOutRaw(this.out, o, this.f[13])
      }
      this.outEnd = jsonOutRaw(this.out, o, this.f[18])
      return 200
    }
    if (kind === K_ARTICLE) {
      if (!this.slugFound[key]) {
        return 404
      }
      const id: i64 = this.slugId[key]
      const slot: i32 = this.idSlot(id)
      if (this.idTable[slot] === 0) {
        return PLAN_ALONE
      }
      const m: i32 = this.idTable[slot] - 1
      // The slug read must be the slug asked for: an update in between could have changed it.
      const r: i32 = this.pageRep[key]
      if (!this.found[m] || !this.slugIs(m, r)) {
        return PLAN_ALONE
      }
      this.outRoom(this.m4[m] - this.m0[m] + 64)
      let o: i32 = jsonOutRaw(this.out, 0, this.f[16])
      o = this.article(o, m, true, v, id, this.slugAuthor[key])
      this.out[o] = toU8(125)
      this.outEnd = o + 1
      return 200
    }
    const start: i32 = this.pageStart[key]
    const n: i32 = this.pageLen[key]
    let size: i32 = 64
    for (let j: i32 = start; j < start + n; j++) {
      const slot: i32 = this.idSlot(this.ids[j])
      if (this.idTable[slot] === 0 || !this.found[this.idTable[slot] - 1]) {
        return PLAN_ALONE
      }
      const m: i32 = this.idTable[slot] - 1
      size += this.m4[m] - this.m0[m] + 32
    }
    this.outRoom(size)
    let o: i32 = jsonOutRaw(this.out, 0, this.f[14])
    for (let j: i32 = start; j < start + n; j++) {
      if (j > start) {
        this.out[o] = toU8(44)
        o++
      }
      o = this.article(o, this.idTable[this.idSlot(this.ids[j])] - 1, false, v, this.ids[j], this.authors[j])
    }
    o = jsonOutRaw(this.out, o, this.f[15])
    const count: i64 = kind === K_GLOBAL ? this.globalCount : this.countValue[this.countOf[i]]
    o = jwtDigits(count, this.out, o)
    this.out[o] = toU8(125)
    this.outEnd = o + 1
    return 200
  }

  /** Article `m` at `out[o]`, with its body when `full`, and viewer `v`'s flags on it and its author. */
  private article(o: i32, m: i32, full: boolean, v: i64, id: i64, author: i64): i32 {
    const t: u8[] = this.text
    const out: u8[] = this.out
    let at: i32 = o
    copyBytes(out, at, t, this.m0[m], this.m1[m] - this.m0[m])
    at += this.m1[m] - this.m0[m]
    if (full) {
      copyBytes(out, at, t, this.m1[m], this.m2[m] - this.m1[m])
      at += this.m2[m] - this.m1[m]
    }
    copyBytes(out, at, t, this.m2[m], this.m3[m] - this.m2[m])
    at += this.m3[m] - this.m2[m]
    at = jsonOutBool(out, at, this.flag(v, id, 0))
    copyBytes(out, at, t, this.m3[m], this.m4[m] - this.m3[m])
    at += this.m4[m] - this.m3[m]
    at = jsonOutBool(out, at, this.flag(v, author, 1))
    return jsonOutRaw(out, at, this.f[13])
  }

  /** Whether article `m`'s slug, as written in its JSON, is request `r`'s key. */
  private slugIs(m: i32, r: i32): boolean {
    // The JSON is `{"slug":"<slug>"`; a slug Postgres stored needs no escape when the key had none.
    const at: i32 = this.m0[m] + toI32(this.f[0].length) + 1
    const n: i32 = this.keyLens[r]
    if (at + n >= this.m1[m] || this.text[at + n] !== toU8(34)) {
      return false
    }
    const s: i32 = this.keyStarts[r]
    for (let k: i32 = 0; k < n; k++) {
      const c: u8 = this.keys[s + k]
      if (c === toU8(34) || c === toU8(92) || c < toU8(32) || this.text[at + k] !== c) {
        return false
      }
    }
    return true
  }

  private outRoom(n: i32): void {
    this.out = grownBytes(this.out, n, 0)
  }
}

const grownI32 = (a: i32[], n: i32, keep: i32): i32[] => {
  if (n <= toI32(a.length)) {
    return a
  }
  let size: i32 = toI32(a.length) < 1024 ? 1024 : toI32(a.length)
  while (size < n) {
    size = size * 2
  }
  const out: i32[] = new Array<i32>(size)
  for (let k: i32 = 0; k < keep && k < toI32(a.length) && k < size; k++) {
    out[k] = a[k]
  }
  return out
}
