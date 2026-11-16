//! Shared contract between the net, api, pg/plan and sec layers (v1, orchestrator).
//! Change only after agreement on .lab/status/BOARD.md; bump the version line above when you do.

/// The authenticated user id from the JWT `sub`, or 0 for anonymous requests.
pub type Viewer = i64;

/// Identifies one client connection. `gen` guards against a slot being reused after the client closed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ConnRef {
    pub reactor: u8,
    pub slot: u32,
    pub gen: u32,
}

/// The 19 Conduit endpoints (SPEC.md).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    UsersLogin,       // POST   /api/users/login
    UsersRegister,    // POST   /api/users
    UserGet,          // GET    /api/user
    UserPut,          // PUT    /api/user
    ProfileGet,       // GET    /api/profiles/:username
    ProfileFollow,    // POST   /api/profiles/:username/follow
    ProfileUnfollow,  // DELETE /api/profiles/:username/follow
    ArticlesList,     // GET    /api/articles?tag=&author=&favorited=&limit=&offset=
    ArticlesFeed,     // GET    /api/articles/feed?limit=&offset=
    ArticleGet,       // GET    /api/articles/:slug
    ArticleCreate,    // POST   /api/articles
    ArticleUpdate,    // PUT    /api/articles/:slug
    ArticleDelete,    // DELETE /api/articles/:slug
    CommentsList,     // GET    /api/articles/:slug/comments
    CommentCreate,    // POST   /api/articles/:slug/comments
    CommentDelete,    // DELETE /api/articles/:slug/comments/:id
    Favorite,         // POST   /api/articles/:slug/favorite
    Unfavorite,       // DELETE /api/articles/:slug/favorite
    Tags,             // GET    /api/tags
}

/// Which list filter a GET /api/articles request uses (at most one is set in the workload; SPEC defines combos).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListFilter {
    Global,
    Tag(Box<str>),
    Author(Box<str>),
    Favorited(Box<str>),
}

/// A validated unit of database work produced by api::admit and executed by the pg drivers.
/// Every variant is answered with exactly one Reply.
#[derive(Debug)]
pub enum Job {
    Tags,
    UserGet,
    Profile { username: Box<str> },
    ArticleGet { slug: Box<str> },
    Comments { slug: Box<str> },
    List { filter: ListFilter, limit: u16, offset: u32 },
    Feed { limit: u16, offset: u32 },
    /// Writes (group-committed; reply only after COMMIT).
    Follow { username: Box<str>, on: bool },
    Favorite { slug: Box<str>, on: bool },
    CommentCreate { slug: Box<str>, body: Box<str> },
    CommentDelete { slug: Box<str>, id: i64 },
    ArticleCreate { title: Box<str>, description: Box<str>, body: Box<str>, tags: Vec<Box<str>> },
    ArticleUpdate { slug: Box<str>, title: Option<Box<str>>, description: Option<Box<str>>, body: Option<Box<str>> },
    ArticleDelete { slug: Box<str> },
    UserUpdate { email: Option<Box<str>>, username: Option<Box<str>>, password_hash: Option<Box<str>>,
                 bio: Option<Option<Box<str>>>, image: Option<Option<Box<str>>> },
    /// Login step 1: fetch the user by email; the pg layer then hands the hash to the kdf worker.
    LoginLookup { email: Box<str>, password: Box<str> },
    /// Signup step 2 (after the kdf worker hashed the password).
    Register { username: Box<str>, email: Box<str>, password_hash: Box<str> },
}

/// A job plus who asked for it.
#[derive(Debug)]
pub struct Envelope {
    pub conn: ConnRef,
    pub viewer: Viewer,
    /// The raw token text when present, so User responses can echo it (GET/PUT /api/user).
    pub token: Option<Box<str>>,
    pub keepalive: bool,
    pub job: Job,
}

/// A complete HTTP response for one connection.
#[derive(Debug)]
pub struct Reply {
    pub conn: ConnRef,
    pub bytes: Vec<u8>,
    pub close: bool,
}

/// bcrypt work for the kdf worker.
#[derive(Debug)]
pub enum KdfJob {
    /// Login: verify `password` against `stored_hash`; on success reply with the user + a fresh token.
    Verify { env_conn: ConnRef, keepalive: bool, password: Box<str>, stored_hash: Box<str>,
             user_id: i64, username: Box<str>, email: Box<str>, bio: Option<Box<str>>, image: Option<Box<str>> },
    /// Signup or password change: hash `password` (cost 10, random salt), then continue with `then`.
    Hash { password: Box<str>, then: Envelope },
}
