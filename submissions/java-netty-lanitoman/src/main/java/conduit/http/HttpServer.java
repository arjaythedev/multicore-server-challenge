package conduit.http;

import conduit.Transport;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.Channel;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.EventLoopGroup;

/** Accepts client connections; each one gets its own {@link HttpConnection}. Idle connections are never closed. */
public final class HttpServer {
    private HttpServer() {
    }

    public static Channel start(EventLoopGroup group, String host, int port) throws InterruptedException {
        return new ServerBootstrap()
                .group(group)
                .channel(Transport.serverChannel())
                .option(ChannelOption.SO_BACKLOG, 65_535)
                .option(ChannelOption.SO_REUSEADDR, true)
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
