package conduit;

import java.util.List;
import java.util.concurrent.Executors;

import io.avaje.inject.BeanScope;
import io.avaje.jex.Jex;
import io.avaje.jex.Routing;

public class Main {

    public static void main(String[] args) {
        BeanScope scope = BeanScope.builder().build();
        List<Routing.HttpService> routes = scope.list(Routing.HttpService.class);

        Jex.create()
                .routing(routes)
                .error(ApiException.class, (ctx, ex) -> ctx.status(ex.status).json(Dto.Errors.of(ex.getMessage())))
                .error(Exception.class, (ctx, ex) -> {
                    System.err.println("unhandled: " + ex);
                    ctx.status(500).json(Dto.Errors.of("internal server error"));
                })
                .config(c -> c.host(Config.env("HOST", "127.0.0.1"))
                        .port(Integer.parseInt(Config.env("PORT", "3000")))
                        // every request on its own virtual thread; a blocked JDBC call unmounts from its carrier
                        .executor(Executors.newVirtualThreadPerTaskExecutor())
                        .socketBacklog(1024))
                .start();
    }
}
