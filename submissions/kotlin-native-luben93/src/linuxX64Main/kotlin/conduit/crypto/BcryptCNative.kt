package conduit.crypto

import conduit.cbcrypt.conduit_bf_lanes
import conduit.cbcrypt.conduit_bf_self_test
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned

/**
 * Kotlin/Native: native/conduit-bcrypt.c compiled into the binary by cinterop (src/nativeInterop/cinterop/bcrypt.def,
 * Kotlin/Native's own clang, -O3), so it is always present; [open] runs its self-test. The calling thread is in
 * native state during a batch, so the GC doesn't wait for it.
 */
internal actual object BcryptC {
    actual fun open(): String? {
        val rc = conduit_bf_self_test()
        return if (rc == 0) null else "self-test failed ($rc)"
    }

    actual fun lanes(n: Int, keys: IntArray, salts: IntArray, cost: Int, out: IntArray) {
        val ok = keys.usePinned { k ->
            salts.usePinned { s ->
                out.usePinned { o -> conduit_bf_lanes(n, k.addressOf(0), s.addressOf(0), cost, o.addressOf(0)) }
            }
        }
        check(ok == 1) { "conduit_bf_lanes($n, cost $cost) failed" }
    }
}
