package conduit;

/** An error with a status, rendered as {"errors":{"body":[message]}}. */
final class ApiException extends RuntimeException {

    final int status;

    ApiException(int status, String message) {
        super(message, null, false, false);
        this.status = status;
    }

    static ApiException invalid(String message) {
        return new ApiException(422, message);
    }

    static ApiException notFound(String what) {
        return new ApiException(404, what + " not found");
    }

    static ApiException unauthorized() {
        return new ApiException(401, "unauthorized");
    }

    static ApiException forbidden() {
        return new ApiException(403, "forbidden");
    }
}
