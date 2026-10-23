class ApiError(Exception):
    """Transport-level error mapped to an HTTP status in the errors.body shape."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message
