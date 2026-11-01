package conduit.http;

import conduit.Transport;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;

/**
 * Accepts client connections, up to {@code maxConnections} at a time ({@link ConnectionLimit}); each one gets its
 * own {@link HttpConnection}. Idle connections are never closed.
 */
public final class HttpServer {
    private HttpServer() {
    }

    /** The default for {@code maxConnections}: what the process's file descriptor limit allows. */
    public static int defaultMaxConnections() {
        return ConnectionLimit.defaultMax();
    }

    public static Channel start(EventLoopGroup group, String host, int port, int maxConnections)
            throws InterruptedException {
        return new ServerBootstrap()
                .group(group)
                .channel(Transport.serverChannel())
                .option(ChannelOption.SO_BACKLOG, 65_535)
                .option(ChannelOption.SO_REUSEADDR, true)
                .handler(new ConnectionLimit(maxConnections))
                .childOption(ChannelOption.TCP_NODELAY, true)
                .childHandler(new ChannelInitializer<>() {
                    @Override
                    protected void initChannel(Channel channel) {
                        channel.pipeline().addLast(new HttpConnection());
                    }
                })
                .bind(host, port)
                .sync()
                .channel();
    }
}
