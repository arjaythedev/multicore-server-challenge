package conduit.http

import conduit.util.ByteBuf

/** No compressor in the Native build yet (HTTP_GZIP has no effect there): responses go out uncompressed. */
actual fun gzip(src: ByteArray, off: Int, len: Int, dst: ByteBuf): Boolean = false
