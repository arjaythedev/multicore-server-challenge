using System.Text.Json.Serialization;

namespace Conduit.Json;

// Requests. Every field is nullable so a missing field reaches the endpoint's own validation (422)
// instead of failing model binding.

public record RegisterRequest(RegisterUser? User);
public record RegisterUser(string? Username, string? Email, string? Password);

public record LoginRequest(LoginUser? User);
public record LoginUser(string? Email, string? Password);

public record UpdateUserRequest(UpdateUser? User);
public record UpdateUser(string? Email, string? Username, string? Password, string? Bio, string? Image);

public record NewArticleRequest(NewArticle? Article);
public record NewArticle(string? Title, string? Description, string? Body, List<string?>? TagList);

public record UpdateArticleRequest(UpdateArticle? Article);
public record UpdateArticle(string? Title, string? Description, string? Body);

public record NewCommentRequest(NewComment? Comment);
public record NewComment(string? Body);

// Responses, shaped as SPEC.md describes.

public record UserResponse(UserDto User);
public record UserDto(string Email, string Token, string Username, string? Bio, string? Image);

public record ProfileResponse(ProfileDto Profile);
public record ProfileDto(string Username, string? Bio, string? Image, bool Following);

public record ArticleResponse(ArticleDto Article);
public record ArticlesResponse(List<ArticleDto> Articles, long ArticlesCount);

/// <summary>Body is null in lists, which leave it out (as the RealWorld spec does).</summary>
public record ArticleDto(
    string Slug,
    string Title,
    string Description,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Body,
    string[] TagList,
    DateTime CreatedAt,
    DateTime UpdatedAt,
    bool Favorited,
    long FavoritesCount,
    ProfileDto Author);

public record CommentResponse(CommentDto Comment);
public record CommentsResponse(List<CommentDto> Comments);
public record CommentDto(long Id, DateTime CreatedAt, DateTime UpdatedAt, string Body, ProfileDto Author);

public record TagsResponse(List<string> Tags);

public record ErrorResponse(ErrorBody Errors);
public record ErrorBody(string[] Body);
