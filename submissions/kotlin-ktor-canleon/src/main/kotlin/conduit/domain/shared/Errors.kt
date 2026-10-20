package conduit.domain.shared

/** A broken business rule. The web layer maps each kind to an HTTP status. No stack trace: these are expected outcomes. */
sealed class DomainException(message: String) : RuntimeException(message, null, false, false)

class NotFoundException(what: String) : DomainException("$what not found")

class ForbiddenException : DomainException("forbidden")

class ValidationException(message: String) : DomainException(message)

class UnauthorizedException(message: String = "unauthorized") : DomainException(message)

fun <T : Any> T?.orNotFound(what: String): T {
    return this ?: throw NotFoundException(what)
}

/** A mandatory text field: present and not empty. */
fun String?.requireNotEmpty(field: String): String {
    if (this.isNullOrEmpty()) throw ValidationException("$field can't be blank")
    return this
}

/** An optional change: null means unchanged, but a given value must not be empty. */
fun String?.requireNotEmptyIfGiven(field: String): String? {
    if (this != null && this.isEmpty()) throw ValidationException("$field can't be blank")
    return this
}
