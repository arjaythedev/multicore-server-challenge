package conduit.errors;

public abstract sealed class AppException extends RuntimeException
    permits Conflict, Forbidden, InvalidInput, NotFound, Unauthenticated {
    protected AppException(String message) {
        super(message);
    }
}
