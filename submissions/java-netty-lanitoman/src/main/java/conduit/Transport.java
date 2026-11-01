package conduit;

import io.netty.channel.EventLoopGroup;
import io.netty.channel.MultiThreadIoEventLoopGroup;
import io.netty.channel.ServerChannel;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollIoHandler;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.epoll.EpollSocketChannel;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.util.concurrent.DefaultThreadFactory;

/**
 * Netty's native epoll transport on Linux, Java NIO elsewhere (only used for development). (io_uring was measured
 * too: no difference for this workload, so the simpler transport stays.)
 */
public final class Transport {
    public static final boolean EPOLL = Epoll.isAvailable();

    private Transport() {
    }

    public static EventLoopGroup newEventLoopGroup(int threads, String name) {
        return new MultiThreadIoEventLoopGroup(threads, new DefaultThreadFactory(name, true),
                EPOLL ? EpollIoHandler.newFactory() : NioIoHandler.newFactory());
    }

    public static Class<? extends ServerChannel> serverChannel() {
        return EPOLL ? EpollServerSocketChannel.class : NioServerSocketChannel.class;
    }

    public static Class<? extends SocketChannel> clientChannel() {
        return EPOLL ? EpollSocketChannel.class : NioSocketChannel.class;
    }

    public static String name() {
        return EPOLL ? "epoll" : "nio";
    }
}
