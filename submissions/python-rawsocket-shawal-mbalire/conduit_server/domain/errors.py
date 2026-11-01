"""Domain errors: raised by outbound adapters in terms the controllers understand, whatever the driver."""


class DuplicateError(Exception):
    """A username or email that another user already has."""
