using Conduit.Json;

namespace Conduit;

/// <summary>Error responses in the RealWorld shape: {"errors": {"body": ["message"]}}.</summary>
public static class ApiErrors
{
    public static ErrorResponse Body(string message) => new(new ErrorBody([message]));

    public static IResult Status(int status, string message) =>
        TypedResults.Json(Body(message), AppJsonContext.Default.ErrorResponse, statusCode: status);

    public static IResult Unauthorized() => Status(StatusCodes.Status401Unauthorized, "unauthorized");

    public static IResult Forbidden() => Status(StatusCodes.Status403Forbidden, "forbidden");

    public static IResult NotFound() => Status(StatusCodes.Status404NotFound, "not found");

    public static IResult Unprocessable(string message) => Status(StatusCodes.Status422UnprocessableEntity, message);
}
