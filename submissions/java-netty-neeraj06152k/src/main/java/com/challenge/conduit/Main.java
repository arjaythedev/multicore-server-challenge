package com.challenge.conduit;

import com.challenge.conduit.config.ServerConfig;
import com.challenge.conduit.db.DatabaseUrl;
import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.Router;
import com.challenge.conduit.security.BcryptPool;
import com.challenge.conduit.security.Jwt;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.*;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollChannelOption;
import io.netty.channel.epoll.EpollEventLoopGroup;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http.FullHttpRequest;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http.HttpServerCodec;

/**
 * Conduit RealWorld Server - Mechanical Sympathy Zero-Framework Java Implementation
 *
 * Direct Netty Epoll (Front: direct) + Vert.x Reactive Postgres Client + FFM 128B Aligned Off-Heap Slabs
 * Fully configurable via external config.properties and environment variables.
 */
public final class Main {

    public static void main(String[] args) throws Exception {
        // 1. Load configuration (config.properties + environment variable overrides)
        ServerConfig config = ServerConfig.load();

        System.out.println("Starting Conduit Server [java-netty-neeraj06152k] on " + config.host() + ":" + config.port()
                + " [JVM: " + System.getProperty("java.vm.name") + " " + System.getProperty("java.version") + "]");
        System.out.println("DB URL: " + config.databaseUrl() + " (pool: " + config.dbPoolMaxSize() + ", pipelining: " + config.dbPipeliningLimit() + ")");

        // 2. Initialize Security & Concurrency Worker Pools
        Jwt jwt = new Jwt(config.jwtSecret(), config.jwtExpirationDays());
        BcryptPool bcryptPool = new BcryptPool(
                config.bcryptWorkerThreads(),
                config.bcryptRingBufferSize(),
                config.bcryptCost()
        );

        // 4. Initialize Reactive Postgres Client
        DatabaseUrl dbUrl = DatabaseUrl.parse(config.databaseUrl());
        PostgresClient pgClient = new PostgresClient(
                dbUrl,
                config.dbPoolMaxSize(),
                config.dbPipeliningLimit(),
                config.dbCachePreparedStatements()
        );

        // 5. Netty Server setup (Thread-per-core)
        boolean useEpoll = Epoll.isAvailable() && config.soReusePort();
        EventLoopGroup bossGroup = useEpoll ? new EpollEventLoopGroup(1) : new NioEventLoopGroup(1);
        EventLoopGroup workerGroup = useEpoll
                ? new EpollEventLoopGroup(config.nettyWorkerThreads())
                : new NioEventLoopGroup(config.nettyWorkerThreads());

        try {
            ServerBootstrap b = new ServerBootstrap();
            b.group(bossGroup, workerGroup)
             .channel(useEpoll ? EpollServerSocketChannel.class : NioServerSocketChannel.class)
             .option(ChannelOption.SO_BACKLOG, config.soBacklog())
             .option(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
             .childOption(ChannelOption.ALLOCATOR, PooledByteBufAllocator.DEFAULT)
             .childOption(ChannelOption.TCP_NODELAY, config.tcpNoDelay())
             .childOption(ChannelOption.SO_KEEPALIVE, config.soKeepAlive());

            if (useEpoll) {
                b.option(EpollChannelOption.SO_REUSEPORT, true);
            }

            b.childHandler(new ChannelInitializer<SocketChannel>() {
                @Override
                protected void initChannel(SocketChannel ch) {
                    ChannelPipeline p = ch.pipeline();
                    p.addLast(new HttpServerCodec(
                            config.maxInitialLineLength(),
                            config.maxHeaderSize(),
                            config.maxChunkSize()
                    ));
                    p.addLast(new HttpObjectAggregator(config.maxContentLength()));
                    p.addLast(new SimpleChannelInboundHandler<FullHttpRequest>() {
                        @Override
                        protected void channelRead0(ChannelHandlerContext ctx, FullHttpRequest req) {
                            Router.route(ctx, req, pgClient, jwt, bcryptPool);
                        }

                        @Override
                        public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
                            ctx.close();
                        }
                    });
                }
            });

            ChannelFuture f = b.bind(config.host(), config.port()).sync();
            System.out.println("Ready on " + config.host() + ":" + config.port());
            f.channel().closeFuture().sync();
        } finally {
            bossGroup.shutdownGracefully();
            workerGroup.shutdownGracefully();
            pgClient.close();
            bcryptPool.shutdown();
        }
    }
}
