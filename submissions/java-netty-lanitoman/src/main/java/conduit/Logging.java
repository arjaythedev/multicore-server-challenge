package conduit;

import java.time.ZoneId;
import java.util.TimeZone;
import java.util.logging.Handler;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

/**
 * Makes sure logging can never take down the thread that logs, in particular an event loop.
 *
 * <p>Netty reports problems through java.util.logging, and its event loops log an unexpected error outside their
 * own error handling. The JDK's console handler prints each record's time in the local time zone, which loads the
 * time-zone database from disk the first time: if that first time comes under overload, with every file descriptor
 * in use, the load fails and the resulting error ends the event loop. So everything logging needs is loaded at
 * startup, and records go to stderr through a handler that formats no times and never throws.
 */
public final class Logging {
    private Logging() {
    }

    /** Call once at startup, before anything is served. */
    public static void install() {
        TimeZone.getDefault();                  // the time-zone data, for anything else that formats a local time
        ZoneId.systemDefault().getRules();
        Logger root = Logger.getLogger("");     // reads the logging configuration file now
        for (Handler handler : root.getHandlers()) root.removeHandler(handler);
        root.addHandler(new PlainHandler());
    }

    /** "LEVEL logger: message", then the stack trace if there is one. */
    private static final class PlainHandler extends Handler {
        @Override
        public void publish(LogRecord record) {
            try {
                if (!isLoggable(record)) return;
                System.err.println(record.getLevel() + " " + record.getLoggerName() + ": " + record.getMessage());
                if (record.getThrown() != null) record.getThrown().printStackTrace();
            } catch (Throwable ignored) {
                // a log line is never worth more than the thread writing it
            }
        }

        @Override
        public void flush() {
            System.err.flush();
        }

        @Override
        public void close() {
        }
    }
}
