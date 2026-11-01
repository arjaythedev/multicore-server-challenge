package conduit.db;

import conduit.Transport;
import io.netty.bootstrap.Bootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;
import io.netty.handler.codec.ByteToMessageDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayDeque;
import java.util.HexFormat;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * One connection to Postgres, speaking protocol 3.0 on a Netty channel: no JDBC, no row objects. After the
 * handshake every statement is prepared once; queries are then pipelined (many can be in flight) and their replies
 * are parsed in place on the connection's event loop, which hands rows straight to the query.
 */
public final class PgConnection extends ByteToMessageDecoder {
    private enum State { AUTHENTICATING, PREPARING, READY, CLOSED }

    private final DatabaseUrl url;
    private final String options;
    private final List<Statement> statements;
    private final CompletableFuture<PgConnection> ready = new CompletableFuture<>();
    private final String name;

    private volatile State state = State.AUTHENTICATING;
    private Channel channel;
    private Scram scram;

    /** Queries sent and not yet completed, oldest first. Only touched on the event loop. */
    private final ArrayDeque<PgQuery> inFlight = new ArrayDeque<>();
    /** Queries submitted and not yet completed; read by other threads to pick the least busy connection. */
    private final AtomicInteger pending = new AtomicInteger();

    // the reply being read: which statement of the current query, and its first error
    private int statementIndex;
    private PgError firstError;
    private final Row row = new Row();

    private PgConnection(DatabaseUrl url, String options, String name) {
        this.url = url;
        this.options = options;
        this.name = name;
        this.statements = Statement.all();
    }

    /** Connects, authenticates and prepares every defined statement. */
    public static CompletableFuture<PgConnection> open(EventLoopGroup group, DatabaseUrl url, String options, String name) {
        PgConnection connection = new PgConnection(url, options, name);
        new Bootstrap()
                .group(group)
                .channel(Transport.clientChannel())
                .option(ChannelOption.TCP_NODELAY, true)
                .handler(connection)
                .connect(url.host(), url.port())
                .addListener(future -> {
                    if (!future.isSuccess()) connection.ready.completeExceptionally(future.cause());
                });
        return connection.ready;
    }

    public String name() {
        return name;
    }

    /** False once the connection is lost (the server doesn't reconnect: a lost connection's queries fail). */
    public boolean isUsable() {
        return state == State.READY;
    }

    /** Number of queries submitted to this connection that haven't completed yet. */
    public int pending() {
        return pending.get();
    }

    /** Closes the connection (used for the one-off startup connection). */
    public void close() {
        channel.eventLoop().execute(() -> {
            state = State.CLOSED;
            channel.close();
        });
    }

    /** Sends a query (from any thread). Its callbacks run later on this connection's event loop. */
    public void submit(PgQuery query) {
        pending.incrementAndGet();
        if (channel.eventLoop().inEventLoop()) send(query);
        else channel.eventLoop().execute(() -> send(query));
    }

    private void send(PgQuery query) {
        if (state != State.READY) {
            pending.decrementAndGet();
            query.onDone(PgError.connectionLost());
            return;
        }
        ByteBuf out = channel.alloc().directBuffer(512);
        query.write(new MessageWriter(out));
        inFlight.addLast(query);
        channel.writeAndFlush(out, channel.voidPromise());
    }

    // ---------- Netty callbacks ----------

    @Override
    public void channelActive(ChannelHandlerContext ctx) throws Exception {
        channel = ctx.channel();
        ByteBuf out = ctx.alloc().buffer(256);
        new MessageWriter(out).startup(url.user(), url.database(), options);
        ctx.writeAndFlush(out);
        super.channelActive(ctx);
    }

    /** Splits the stream into messages: type byte, Int32 length (including itself), body. */
    @Override
    protected void decode(ChannelHandlerContext ctx, ByteBuf in, List<Object> unused) throws Exception {
        while (in.readableBytes() >= 5) {
            int length = in.getInt(in.readerIndex() + 1);
            if (in.readableBytes() < 1 + length) return;
            byte type = in.readByte();
            in.skipBytes(4);
            ByteBuf body = in.readSlice(length - 4);
            if (state != State.READY) {
                onStartupMessage(ctx, type, body);
                continue;
            }
            try {
                onReply(type, body);
            } catch (RuntimeException e) {
                // a bug in a query's callback must not take the connection (and every other query on it) down
                e.printStackTrace();
            }
        }
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) throws Exception {
        if (state != State.CLOSED) {
            System.err.println("postgres connection " + name + " closed");
            failAll(PgError.connectionLost());
        }
        super.channelInactive(ctx);
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        System.err.println("postgres connection " + name + " failed: " + cause);
        failAll(PgError.connectionLost());
        ctx.close();
    }

    private void failAll(PgError error) {
        state = State.CLOSED;
        ready.completeExceptionally(new IllegalStateException("postgres: " + error));
        PgQuery query;
        while ((query = inFlight.pollFirst()) != null) {
            pending.decrementAndGet();
            try {
                query.onDone(error);
            } catch (RuntimeException e) {
                e.printStackTrace();
            }
        }
    }

    // ---------- replies to queries ----------

    private void onReply(byte type, ByteBuf body) {
        switch (type) {
            case 'D' -> {                                   // DataRow
                if (firstError != null) return;
                row.load(body);
                inFlight.peekFirst().onRow(statementIndex, row);
            }
            case 'C' -> {                                   // CommandComplete
                if (firstError == null) inFlight.peekFirst().onCommandComplete(statementIndex, cString(body));
                statementIndex++;
            }
            case 'E' -> {                                   // ErrorResponse: the rest of the query is skipped
                if (firstError == null) firstError = parseError(body);
            }
            case 'Z' -> {                                   // ReadyForQuery: the query is complete
                PgQuery query = inFlight.pollFirst();
                PgError error = firstError;
                firstError = null;
                statementIndex = 0;
                pending.decrementAndGet();
                query.onDone(error);
            }
            default -> {
                // ParseComplete, BindComplete, NoData, notices, parameter status changes: nothing to do
            }
        }
    }

    // ---------- startup: authentication, then preparing the statements ----------

    private void onStartupMessage(ChannelHandlerContext ctx, byte type, ByteBuf body) throws Exception {
        switch (type) {
            case 'R' -> authenticate(ctx, body);
            case 'E' -> {
                PgError error = parseError(body);
                state = State.CLOSED;
                ready.completeExceptionally(new IllegalStateException("postgres: " + error));
                ctx.close();
            }
            case 'Z' -> {
                if (state == State.AUTHENTICATING) {
                    state = State.PREPARING;
                    ByteBuf out = ctx.alloc().buffer(16 * 1024);
                    MessageWriter writer = new MessageWriter(out);
                    for (Statement statement : statements) writer.parse(statement);
                    writer.sync();
                    ctx.writeAndFlush(out);
                } else if (state == State.PREPARING) {
                    state = State.READY;
                    ready.complete(this);
                }
            }
            default -> {
                // ParameterStatus, BackendKeyData, ParseComplete, notices
            }
        }
    }

    private void authenticate(ChannelHandlerContext ctx, ByteBuf body) throws Exception {
        int code = body.readInt();
        ByteBuf out = ctx.alloc().buffer(256);
        MessageWriter writer = new MessageWriter(out);
        switch (code) {
            case 0 -> {                                      // AuthenticationOk
                out.release();
                return;
            }
            case 3 -> writer.password((url.password() + "\0").getBytes(StandardCharsets.UTF_8));
            case 5 -> {                                      // MD5: "md5" + md5(md5(password + user) + salt)
                byte[] salt = new byte[4];
                body.readBytes(salt);
                String inner = md5Hex(concat((url.password() + url.user()).getBytes(StandardCharsets.UTF_8)));
                String outer = md5Hex(concat(inner.getBytes(StandardCharsets.US_ASCII), salt));
                writer.password(("md5" + outer + "\0").getBytes(StandardCharsets.US_ASCII));
            }
            case 10 -> {                                     // SASL: start SCRAM-SHA-256
                scram = new Scram(url.password());
                writer.password(scram.clientFirstMessage());
            }
            case 11 -> writer.password(scram.clientFinalMessage(body.toString(StandardCharsets.UTF_8)));
            case 12 -> {                                     // SASL final: the server proves it knows the password
                scram.verifyServerFinal(body.toString(StandardCharsets.UTF_8));
                out.release();
                return;
            }
            default -> {
                out.release();
                throw new IllegalStateException("unsupported Postgres authentication method " + code);
            }
        }
        ctx.writeAndFlush(out);
    }

    // ---------- helpers ----------

    /** ErrorResponse: fields of a type byte and a C string, ended by a zero byte. 'C' is the SQLSTATE. */
    private static PgError parseError(ByteBuf body) {
        String sqlState = "XX000";
        String message = "";
        int position = body.readerIndex();
        int end = body.writerIndex();
        while (position < end) {
            byte field = body.getByte(position++);
            if (field == 0) break;
            int terminator = body.indexOf(position, end, (byte) 0);
            if (terminator < 0) break;
            String value = body.toString(position, terminator - position, StandardCharsets.UTF_8);
            if (field == 'C') sqlState = value;
            else if (field == 'M') message = value;
            position = terminator + 1;
        }
        return new PgError(sqlState, message);
    }

    private static String cString(ByteBuf body) {
        int length = body.readableBytes();
        if (length > 0 && body.getByte(body.readerIndex() + length - 1) == 0) length--;
        return body.toString(body.readerIndex(), length, StandardCharsets.UTF_8);
    }

    private static byte[] concat(byte[]... parts) {
        int total = 0;
        for (byte[] part : parts) total += part.length;
        byte[] result = new byte[total];
        int at = 0;
        for (byte[] part : parts) {
            System.arraycopy(part, 0, result, at, part.length);
            at += part.length;
        }
        return result;
    }

    private static String md5Hex(byte[] data) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(data));
    }
}
