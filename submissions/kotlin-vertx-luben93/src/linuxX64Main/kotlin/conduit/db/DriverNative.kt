package conduit.db

/** Kotlin/Native has no third-party driver: DB_DRIVER is JVM-only. */
actual fun driverBackend(driver: String, config: DbConfig, reads: List<ReadKind>, writes: List<WriteStmt>): DbBackend? =
    null
