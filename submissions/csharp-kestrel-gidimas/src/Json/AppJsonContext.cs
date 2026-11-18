using System.Text.Json;
using System.Text.Json.Serialization;

namespace Conduit.Json;

/// <summary>Source-generated serialization for the request and response types (web defaults: camelCase).</summary>
[JsonSourceGenerationOptions(JsonSerializerDefaults.Web, Converters = [typeof(TimestampConverter)])]
[JsonSerializable(typeof(RegisterRequest))]
[JsonSerializable(typeof(LoginRequest))]
[JsonSerializable(typeof(UpdateUserRequest))]
[JsonSerializable(typeof(NewArticleRequest))]
[JsonSerializable(typeof(UpdateArticleRequest))]
[JsonSerializable(typeof(NewCommentRequest))]
[JsonSerializable(typeof(UserResponse))]
[JsonSerializable(typeof(ProfileResponse))]
[JsonSerializable(typeof(ArticleResponse))]
[JsonSerializable(typeof(ArticlesResponse))]
[JsonSerializable(typeof(CommentResponse))]
[JsonSerializable(typeof(CommentsResponse))]
[JsonSerializable(typeof(TagsResponse))]
[JsonSerializable(typeof(ErrorResponse))]
public partial class AppJsonContext : JsonSerializerContext;
