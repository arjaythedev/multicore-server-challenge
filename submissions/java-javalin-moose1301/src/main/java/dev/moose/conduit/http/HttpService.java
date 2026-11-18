package dev.moose.conduit.http;

import dev.moose.conduit.config.ConduitConfig;
import io.javalin.Javalin;
import io.javalin.compression.CompressionStrategy;
import lombok.RequiredArgsConstructor;
import org.eclipse.jetty.server.Handler;
import org.eclipse.jetty.server.HttpConnectionFactory;
import org.eclipse.jetty.server.LowResourceMonitor;
import org.eclipse.jetty.server.ServerConnector;
import org.eclipse.jetty.util.thread.QueuedThreadPool;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@RequiredArgsConstructor
public class HttpService {

    private static final Logger LOGGER = LoggerFactory.getLogger(HttpService.class);

    private final ConduitConfig config;

    public void start() {
        final QueuedThreadPool threadPool = new QueuedThreadPool(this.config.getHttpThreads(),
                Math.min(this.config.getHttpThreads(), this.config.getCores() * 2), 60_000);
        threadPool.setName("http");

        Javalin.create(javalinConfig -> {
            javalinConfig.startup.showJavalinBanner = false;
            javalinConfig.startup.startupWatcherEnabled = false;
            javalinConfig.http.compressionStrategy = CompressionStrategy.NONE;
            javalinConfig.http.generateEtags = false;
            javalinConfig.jetty.threadPool = threadPool;
            javalinConfig.jetty.modifyServer(server -> {
                server.getBeans(LowResourceMonitor.class).forEach(server::removeBean);
                server.setHandler((Handler) null);
            });
            javalinConfig.jetty.modifyHttpConfiguration(httpConfiguration -> {
                httpConfiguration.setSendServerVersion(false);
                httpConfiguration.setSendXPoweredBy(false);
                httpConfiguration.setSendDateHeader(false);
                httpConfiguration.setHeaderCacheSize(0);
            });
            javalinConfig.jetty.addConnector((server, httpConfiguration) -> {
                final ServerConnector connector = new ServerConnector(server, 1, this.config.getSelectors(),
                        new HttpConnectionFactory(httpConfiguration));
                connector.setHost(this.config.getHost());
                connector.setPort(this.config.getPort());
                connector.setIdleTimeout(this.config.getIdleTimeoutMillis());
                connector.setAcceptQueueSize(16384);
                connector.setReuseAddress(true);
                return connector;
            });
            new Api().routes(javalinConfig.routes);
        }).start();

        LOGGER.info("Listening on {}:{} ({} read lanes, {} write connections, {} selectors)", this.config.getHost(),
                this.config.getPort(), this.config.getReadLanes(), this.config.getWriteConnections(),
                this.config.getSelectors());
    }

}
