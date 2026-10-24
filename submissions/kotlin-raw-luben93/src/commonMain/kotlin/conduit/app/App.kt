package conduit.app

import conduit.db.ReadKind
import conduit.db.WriteStmt
import conduit.http.Exchange

/** The Conduit API: routing, auth, validation, SQL and JSON for all 19 endpoints. */
object App {
    /** Every batched read statement, prepared on every connection at startup. */
    val reads: List<ReadKind> get() = TODO("app: App.reads")

    /** Every write statement, prepared on every connection at startup. */
    val writes: List<WriteStmt> get() = TODO("app: App.writes")

    /** Handles one request; must answer it exactly once (see [Exchange]). */
    suspend fun handle(ex: Exchange): Unit = TODO("app: App.handle")
}
