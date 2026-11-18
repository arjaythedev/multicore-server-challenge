using Conduit.Json;

namespace Conduit.Data;

// Rows as the statements in Sql return them. Dapper maps snake_case columns to these properties
// (DefaultTypeMap.MatchNamesWithUnderscores, set in Program.cs).

public sealed class UserRow
{
    public long Id { get; init; }
    public string Username { get; init; } = "";
    public string Email { get; init; } = "";
    public string? Bio { get; init; }
    public string? Image { get; init; }
    public string PasswordHash { get; init; } = "";

    public UserDto ToDto(string token) => new(Email, token, Username, Bio, Image);
}

public sealed class ProfileRow
{
    public long Id { get; init; }
    public string Username { get; init; } = "";
    public string? Bio { get; init; }
    public string? Image { get; init; }
    public bool Following { get; init; }

    public ProfileDto ToDto() => new(Username, Bio, Image, Following);
}

/// <summary>An article with its author; Body is null in list rows.</summary>
public sealed class ArticleRow
{
    public long Id { get; init; }
    public string Slug { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string? Body { get; init; }
    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; init; }
    public string[] TagList { get; init; } = [];
    public long FavoritesCount { get; init; }
    public bool Favorited { get; init; }
    public string Username { get; init; } = "";
    public string? Bio { get; init; }
    public string? Image { get; init; }
    public bool Following { get; init; }

    public ArticleDto ToDto() => new(
        Slug, Title, Description, Body, TagList, CreatedAt, UpdatedAt, Favorited, FavoritesCount,
        new ProfileDto(Username, Bio, Image, Following));
}

public sealed class ArticleOwnerRow
{
    public long Id { get; init; }
    public long AuthorId { get; init; }
}

public sealed class CommentRow
{
    public long Id { get; init; }
    public string Body { get; init; } = "";
    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; init; }
    public string Username { get; init; } = "";
    public string? Bio { get; init; }
    public string? Image { get; init; }
    public bool Following { get; init; }

    public CommentDto ToDto() => new(Id, CreatedAt, UpdatedAt, Body, new ProfileDto(Username, Bio, Image, Following));
}
