package conduit;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * How a controller method treats the {@code Authorization} header. A method without this annotation is
 * {@link Level#REQUIRED}, so a new endpoint is protected until it says otherwise. {@link AccessTable} reads these at
 * startup and {@link AuthFilter} enforces them before the request body is bound.
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
@interface Access {

    enum Level {
        /** The token is ignored (register, login, tags). */
        NONE,
        /** No token means anonymous; a token that is present but invalid is a 401. */
        OPTIONAL,
        /** A missing or invalid token is a 401. */
        REQUIRED
    }

    Level value();
}
