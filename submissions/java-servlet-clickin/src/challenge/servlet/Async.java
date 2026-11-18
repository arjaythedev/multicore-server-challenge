package challenge.servlet;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import challenge.http.Task;
import jakarta.servlet.AsyncContext;
import jakarta.servlet.AsyncEvent;
import jakarta.servlet.AsyncListener;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.ServletContext;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;

/**
 * The request's {@link jakarta.servlet.AsyncContext}, pooled with it.
 * Everything runs on the request's loop thread: {@link #start} and {@link
 * #dispatch} post a pooled task to the loop instead of handing work to a thread
 * pool, so a runnable given to {@code start} must not block. The timeout is
 * stored but not enforced.
 */
final class Async implements AsyncContext {
    private final Request request;
    private final Response response;
    private final List<AsyncListener> listeners = new ArrayList<>(0);
    private long timeout = 30_000;
    private final Run run = new Run();
    private final Dispatch dispatch = new Dispatch();

    Async(Request request, Response response) {
        this.request = request;
        this.response = response;
    }

    /**
     * Runs a {@link #start} runnable; one per context, and a second start
     * before it ran queues a fresh one.
     */
    private static final class Run extends Task {
        Runnable target;

        public void run() {
            Runnable r = target;
            target = null;
            r.run();
        }
    }

    /** Runs the request through the container again with an ASYNC dispatch type. */
    private final class Dispatch extends Task {
        public void run() {
            request.redispatch = false;
            request.dispatcherType = DispatcherType.ASYNC;
            try {
                response.container().service(request, response);
            } catch (ServletException | IOException | RuntimeException e) {
                e.printStackTrace();
                response.reset();
                response.setStatus(500);
            }
            if (!request.asyncPending()) {
                finish();
            }
        }
    }

    public ServletRequest getRequest() {
        return request;
    }

    public ServletResponse getResponse() {
        return response;
    }

    public boolean hasOriginalRequestAndResponse() {
        return true;
    }

    public void complete() {
        request.loop().assertLoopThread();
        request.completed();
        finish();
    }

    private void finish() {
        if (!listeners.isEmpty()) {
            AsyncEvent event = new AsyncEvent(this, request, response);
            for (AsyncListener l : listeners) {
                try {
                    l.onComplete(event);
                } catch (IOException e) {
                    e.printStackTrace();
                }
            }
            listeners.clear();
        }
        timeout = 30_000;
        response.finish.run();
    }

    public void start(Runnable runnable) {
        Run task = run;
        if (task.target != null) {
            task = new Run();
        }
        task.target = runnable;
        request.loop().post(task);
    }

    /**
     * Ends this async cycle and re-dispatches the original request; the
     * response completes after that dispatch.
     */
    public void dispatch() {
        request.completed();
        request.redispatch = true;
        request.loop().post(dispatch);
    }

    /**
     * Only the original path can be dispatched to: there is no request
     * dispatcher for other paths.
     */
    public void dispatch(String path) {
        throw new UnsupportedOperationException("dispatch to another path");
    }

    public void dispatch(ServletContext context, String path) {
        throw new UnsupportedOperationException("dispatch to another path");
    }

    public void addListener(AsyncListener listener) {
        listeners.add(listener);
    }

    public void addListener(AsyncListener listener, ServletRequest req, ServletResponse res) {
        listeners.add(listener);
    }

    public <T extends AsyncListener> T createListener(Class<T> type) throws ServletException {
        try {
            return type.getDeclaredConstructor().newInstance();
        } catch (ReflectiveOperationException e) {
            throw new ServletException(e);
        }
    }

    public void setTimeout(long millis) {
        timeout = millis;
    }

    public long getTimeout() {
        return timeout;
    }
}
