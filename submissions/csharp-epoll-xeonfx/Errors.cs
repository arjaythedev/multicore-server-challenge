using System;

/// <summary>
/// Whole error bodies in the spec's shape, {"errors": {"body": ["message"]}}, encoded at compile time: an error
/// response copies one span, with no writer and no string. The comment on each is the status it goes with.
/// </summary>
static class Errors
{
    /// <summary>404: no route</summary>
    public static ReadOnlySpan<byte> NotFound => """{"errors":{"body":["not found"]}}"""u8;

    /// <summary>401</summary>
    public static ReadOnlySpan<byte> Unauthorized => """{"errors":{"body":["unauthorized"]}}"""u8;

    /// <summary>400: malformed framing</summary>
    public static ReadOnlySpan<byte> BadRequest => """{"errors":{"body":["bad request"]}}"""u8;

    /// <summary>413</summary>
    public static ReadOnlySpan<byte> BodyTooLarge => """{"errors":{"body":["request body too large"]}}"""u8;

    /// <summary>500</summary>
    public static ReadOnlySpan<byte> Internal => """{"errors":{"body":["internal error"]}}"""u8;

    /// <summary>422: not {"wrapper": {...}}</summary>
    public static ReadOnlySpan<byte> InvalidBody => """{"errors":{"body":["invalid body"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> RegisterFields => """{"errors":{"body":["username, email and password are required"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> LoginFields => """{"errors":{"body":["email and password are required"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> UserFields => """{"errors":{"body":["invalid user fields"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> PasswordTooLong => """{"errors":{"body":["password is too long"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> Taken => """{"errors":{"body":["username or email is already taken"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> BadPage => """{"errors":{"body":["limit must be 1-100 and offset >= 0"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> ArticleFields => """{"errors":{"body":["title, description and body are required"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> ArticleUpdateFields => """{"errors":{"body":["title, description and body must be non-empty strings"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> BadTagList => """{"errors":{"body":["tagList must be an array of non-empty strings"]}}"""u8;

    /// <summary>422</summary>
    public static ReadOnlySpan<byte> CommentFields => """{"errors":{"body":["body is required"]}}"""u8;

    /// <summary>401</summary>
    public static ReadOnlySpan<byte> WrongLogin => """{"errors":{"body":["invalid email or password"]}}"""u8;

    /// <summary>403</summary>
    public static ReadOnlySpan<byte> NotTheAuthor => """{"errors":{"body":["not the author"]}}"""u8;

    /// <summary>404</summary>
    public static ReadOnlySpan<byte> ArticleNotFound => """{"errors":{"body":["article not found"]}}"""u8;

    /// <summary>404</summary>
    public static ReadOnlySpan<byte> CommentNotFound => """{"errors":{"body":["comment not found"]}}"""u8;

    /// <summary>404</summary>
    public static ReadOnlySpan<byte> ProfileNotFound => """{"errors":{"body":["profile not found"]}}"""u8;

    /// <summary>503: a lock or statement timeout</summary>
    public static ReadOnlySpan<byte> DatabaseBusy => """{"errors":{"body":["the database is busy"]}}"""u8;

    /// <summary>503</summary>
    public static ReadOnlySpan<byte> TooManyLogins => """{"errors":{"body":["too many logins are waiting"]}}"""u8;

    /// <summary>503</summary>
    public static ReadOnlySpan<byte> TooManyReads => """{"errors":{"body":["too many reads are waiting"]}}"""u8;

    /// <summary>503</summary>
    public static ReadOnlySpan<byte> TooManyWrites => """{"errors":{"body":["too many writes are waiting"]}}"""u8;
}
