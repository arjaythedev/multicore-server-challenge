package conduit.pg

import conduit.platform.BlockingSocket
import conduit.platform.Monitor
import conduit.util.ByteBuf
import conduit.util.intBE
import conduit.util.shortBE
import kotlin.jvm.JvmField

/** The connection is unusable (EOF, I/O error, protocol violation); requests on it fail with 08006. */
class PgIoException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** An ErrorResponse where there is no [Result] to put it in (startup, prepare, simple query). */
class PgException(val error: PgError, context: String) : Exception("$context: ${error.code} ${error.message}")

/** One statement to prepare: [name] is the protocol-level statement name, [label] says what it is in errors. */
class PgStatement(val name: String, val sql: String, val oids: IntArray, val label: String)

/**
 * One Postgres connection: protocol 3.0, extended query protocol, binary formats, over a blocking socket.
 *
 * Receiving is done by one thread (the connection's worker). Messages are parsed in place in [rbuf]; DataRows are
 * handed out as offsets into it, so within one reply the buffer is never compacted, only grown by copying
 * everything to a bigger array at the same offsets ([beginReply] compacts between replies).
 *
 * Sending: encode into [out], then [send]. The caller guarantees one encoder at a time (the db layer only lets the
 * thread that owns the connection's current batch touch [out]). [send] and [close] are serialized so a send can
 * never hit a closed (and possibly reused) file descriptor.
 */
class PgConn private constructor(private val sock: BlockingSocket) {
    @JvmField var rbuf = ByteArray(INITIAL_RBUF)
    @JvmField var rpos = 0
    @JvmField var rlen = 0

    /** Body offset and length of the message [next] returned (after the type byte and the Int32 length). */
    @JvmField var mstart = 0
    @JvmField var mlen = 0

    @JvmField val out = ByteBuf(16384)

    /** BackendKeyData process id (diagnostics, pg_terminate_backend in tests). */
    @JvmField var backendPid = 0

    private val sendLock = Monitor()
    private var closed = false

    /** Reads the next complete message (blocking) and returns its type byte. Throws [PgIoException]. */
    fun next(): Int {
        while (true) {
            val avail = rlen - rpos
            if (avail >= 5) {
                val len = rbuf.intBE(rpos + 1)
                if (len < 4 || len > MAX_MESSAGE) throw PgIoException("protocol: bad message length $len")
                if (avail > len) {
                    val t = rbuf[rpos].toInt()
                    mstart = rpos + 5
                    mlen = len - 4
                    rpos += len + 1
                    return t
                }
                room(len + 1 - avail)
            } else {
                room(5 - avail)
            }
            val n = try {
                sock.read(rbuf, rlen, rbuf.size - rlen)
            } catch (e: Throwable) {
                throw PgIoException("recv: ${e.message ?: e}", e)
            }
            if (n <= 0) throw PgIoException("connection closed by the server")
            rlen += n
        }
    }

    /** Makes the message [next] just returned the next one again. */
    fun pushBack() {
        rpos = mstart - 5
    }

    private fun room(need: Int) {
        if (rbuf.size - rlen >= need) return
        var cap = rbuf.size * 2
        while (cap - rlen < need) cap *= 2
        rbuf = rbuf.copyOf(cap)
    }

    /** Called between replies (no Row of a previous reply is in use any more): compacts the receive buffer. */
    fun beginReply() {
        if (rpos == rlen) {
            rpos = 0
            rlen = 0
            if (rbuf.size > MAX_KEEP_RBUF) rbuf = ByteArray(INITIAL_RBUF)
        } else if (rpos > 0) {
            rbuf.copyInto(rbuf, 0, rpos, rlen)
            rlen -= rpos
            rpos = 0
        }
    }

    /** Writes out[0, out.len). Throws [PgIoException]. */
    fun send() {
        sendLock.lock()
        try {
            if (closed) throw PgIoException("connection closed")
            sock.writeFully(out.buf, 0, out.len)
        } catch (e: PgIoException) {
            throw e
        } catch (e: Throwable) {
            throw PgIoException("send: ${e.message ?: e}", e)
        } finally {
            sendLock.unlock()
        }
    }

    /** Idempotent. Only the reading thread closes a live connection (a close does not wake a blocked read). */
    fun close() {
        sendLock.lock()
        try {
            if (!closed) {
                closed = true
                try {
                    sock.close()
                } catch (_: Throwable) {
                }
            }
        } finally {
            sendLock.unlock()
        }
    }

    /** Parses the current ErrorResponse: SQLSTATE ('C') and message ('M'). */
    fun error(): PgError {
        var code = "XX000"
        var message = ""
        var p = mstart
        val end = mstart + mlen
        while (p < end) {
            val field = rbuf[p].toInt()
            if (field == 0) break
            p++
            var z = p
            while (z < end && rbuf[z].toInt() != 0) z++
            when (field) {
                'C'.code -> code = rbuf.decodeToString(p, z)
                'M'.code -> message = rbuf.decodeToString(p, z)
            }
            p = z + 1
        }
        return PgError(code, message)
    }

    /** Row count of the current CommandComplete tag: "INSERT 0 1" -> 1, "SELECT 5" -> 5, "BEGIN" -> 0. */
    fun tagCount(): Long {
        var end = mstart
        val limit = mstart + mlen
        while (end < limit && rbuf[end].toInt() != 0) end++
        var p = end
        while (p > mstart && rbuf[p - 1] >= DIGIT_0 && rbuf[p - 1] <= DIGIT_9) p--
        var n = 0L
        while (p < end) n = n * 10 + (rbuf[p++] - DIGIT_0)
        return n
    }

    /** Transaction status of the current ReadyForQuery: 'I' idle, 'T' in a transaction, 'E' failed transaction. */
    fun txStatus(): Int = rbuf[mstart].toInt()

    private fun startup(user: String, password: String, database: String, options: String, appName: String) {
        val o = out
        o.reset()
        o.putIntBE(0)
        o.putIntBE(PROTOCOL_3_0)
        for ((k, v) in listOf(
            "user" to user, "database" to database, "options" to options,
            "client_encoding" to "UTF8", "application_name" to appName,
        )) {
            if (v.isEmpty()) continue
            o.putAscii(k)
            o.put(0)
            o.putUtf8(v)
            o.put(0)
        }
        o.put(0)
        o.setIntBE(0, o.len)
        send()
        var scram: Scram? = null
        while (true) {
            when (next()) {
                'R'.code -> when (val method = rbuf.intBE(mstart)) {
                    0 -> {} // AuthenticationOk
                    3 -> passwordMessage(password) // cleartext
                    5 -> passwordMessage(Md5.password(user, password, rbuf.copyOfRange(mstart + 4, mstart + 8)))
                    10 -> { // AuthenticationSASL: mechanism list
                        val mechanisms = cstrings(mstart + 4, mstart + mlen)
                        if ("SCRAM-SHA-256" !in mechanisms) {
                            throw PgIoException("no supported SASL mechanism in $mechanisms")
                        }
                        val s = Scram(password)
                        scram = s
                        val first = s.clientFirst.encodeToByteArray()
                        o.reset()
                        o.put('p'.code)
                        val lp = o.len
                        o.putIntBE(0)
                        o.putAscii("SCRAM-SHA-256")
                        o.put(0)
                        o.putIntBE(first.size)
                        o.put(first)
                        o.setIntBE(lp, o.len - lp)
                        send()
                    }
                    11 -> { // AuthenticationSASLContinue: server-first-message
                        val s = scram ?: throw PgIoException("SASLContinue before SASL")
                        val fin = s.clientFinal(rbuf.decodeToString(mstart + 4, mstart + mlen))
                        o.reset()
                        o.put('p'.code)
                        o.putIntBE(4 + fin.length)
                        o.putAscii(fin)
                        send()
                    }
                    12 -> { // AuthenticationSASLFinal: server-final-message
                        val s = scram ?: throw PgIoException("SASLFinal before SASL")
                        s.verifyServerFinal(rbuf.decodeToString(mstart + 4, mstart + mlen))
                    }
                    else -> throw PgIoException("unsupported authentication method $method")
                }
                'E'.code -> throw PgException(error(), "startup")
                'K'.code -> backendPid = rbuf.intBE(mstart)
                'Z'.code -> return
                else -> {} // ParameterStatus, NoticeResponse
            }
        }
    }

    private fun passwordMessage(pw: String) {
        val o = out
        o.reset()
        o.put('p'.code)
        val lp = o.len
        o.putIntBE(0)
        o.putUtf8(pw)
        o.put(0)
        o.setIntBE(lp, o.len - lp)
        send()
    }

    private fun cstrings(from: Int, to: Int): List<String> {
        val list = ArrayList<String>()
        var p = from
        while (p < to && rbuf[p].toInt() != 0) {
            var z = p
            while (z < to && rbuf[z].toInt() != 0) z++
            list.add(rbuf.decodeToString(p, z))
            p = z + 1
        }
        return list
    }

    /**
     * Parses every statement (explicit parameter OIDs, no Describe: result layouts are known statically and all
     * results are requested in binary), then one Sync. Throws [PgException] naming the first statement that failed.
     */
    fun prepare(statements: List<PgStatement>) {
        val o = out
        o.reset()
        for (s in statements) {
            o.put('P'.code)
            val lp = o.len
            o.putIntBE(0)
            o.putUtf8(s.name)
            o.put(0)
            o.putUtf8(s.sql)
            o.put(0)
            o.putShortBE(s.oids.size)
            for (oid in s.oids) o.putIntBE(oid)
            o.setIntBE(lp, o.len - lp)
        }
        o.put(SYNC)
        send()
        var parsed = 0
        var err: PgError? = null
        var errAt = 0
        while (true) {
            when (next()) {
                '1'.code -> parsed++
                'E'.code -> if (err == null) {
                    err = error()
                    errAt = parsed
                }
                'Z'.code -> break
            }
        }
        if (err != null) {
            val s = statements[errAt]
            throw PgException(err, "prepare ${s.name} (${s.label}): ${s.sql.take(160).replace('\n', ' ')}")
        }
    }

    /**
     * Simple-query protocol, text results: for admin commands and tests only (CREATE DATABASE, pg_terminate_backend).
     * Throws [PgException] on an ErrorResponse.
     */
    fun simpleQuery(sql: String): List<List<String?>> {
        val o = out
        o.reset()
        o.put('Q'.code)
        val lp = o.len
        o.putIntBE(0)
        o.putUtf8(sql)
        o.put(0)
        o.setIntBE(lp, o.len - lp)
        send()
        val rows = ArrayList<List<String?>>()
        var err: PgError? = null
        while (true) {
            when (next()) {
                'D'.code -> {
                    val n = rbuf.shortBE(mstart)
                    var p = mstart + 2
                    val row = ArrayList<String?>(n)
                    for (c in 0 until n) {
                        val l = rbuf.intBE(p)
                        p += 4
                        if (l < 0) row.add(null) else {
                            row.add(rbuf.decodeToString(p, p + l))
                            p += l
                        }
                    }
                    rows.add(row)
                }
                'E'.code -> if (err == null) err = error()
                'Z'.code -> break
            }
        }
        if (err != null) throw PgException(err, sql.take(160))
        return rows
    }

    companion object {
        private const val PROTOCOL_3_0 = 196608
        private const val INITIAL_RBUF = 128 * 1024
        private const val MAX_KEEP_RBUF = 4 * 1024 * 1024
        private const val MAX_MESSAGE = 1 shl 30
        private const val DIGIT_0: Byte = 48
        private const val DIGIT_9: Byte = 57

        /** Execute (unnamed portal, all rows). */
        val EXECUTE = byteArrayOf('E'.code.toByte(), 0, 0, 0, 9, 0, 0, 0, 0, 0)
        val SYNC = byteArrayOf('S'.code.toByte(), 0, 0, 0, 4)

        /** Connects, authenticates (SCRAM-SHA-256, MD5 or cleartext) and waits for the first ReadyForQuery. */
        fun connect(
            host: String, port: Int, user: String, password: String, database: String, options: String,
            appName: String = "conduit",
        ): PgConn {
            val sock = try {
                BlockingSocket.connect(host, port)
            } catch (e: Throwable) {
                throw PgIoException("connect $host:$port: ${e.message ?: e}", e)
            }
            val c = PgConn(sock)
            try {
                c.startup(user, password, database, options, appName)
            } catch (e: Throwable) {
                c.close()
                throw e
            }
            return c
        }

        /** Statement name as a C string, for [beginBind]. */
        fun cstr(s: String): ByteArray = s.encodeToByteArray() + 0
    }
}

/**
 * Starts a Bind of statement [cstrName] (NUL-terminated) to the unnamed portal with [nParams] parameters, all in
 * binary. Append the parameter values (Int32 length + bytes each), then call [endBindExecute] with the returned
 * position.
 */
fun ByteBuf.beginBind(cstrName: ByteArray, nParams: Int): Int {
    put('B'.code)
    val lp = len
    putIntBE(0)
    put(0) // unnamed portal
    put(cstrName)
    putShortBE(1) // one parameter format code ...
    putShortBE(1) // ... binary, for all parameters
    putShortBE(nParams)
    return lp
}

/** Finishes a Bind (every result column binary) and appends Execute (all rows). */
fun ByteBuf.endBindExecute(lenPos: Int) {
    putShortBE(1)
    putShortBE(1)
    setIntBE(lenPos, len - lenPos)
    put(PgConn.EXECUTE)
}

fun ByteBuf.sync() = put(PgConn.SYNC)
