using System.Text.Json;

namespace Conduit.Http;

/// <summary>Property names, encoded once.</summary>
public static class Names
{
    public static readonly JsonEncodedText User = JsonEncodedText.Encode("user");
    public static readonly JsonEncodedText Profile = JsonEncodedText.Encode("profile");
    public static readonly JsonEncodedText Article = JsonEncodedText.Encode("article");
    public static readonly JsonEncodedText Articles = JsonEncodedText.Encode("articles");
    public static readonly JsonEncodedText ArticlesCount = JsonEncodedText.Encode("articlesCount");
    public static readonly JsonEncodedText Comment = JsonEncodedText.Encode("comment");
    public static readonly JsonEncodedText Comments = JsonEncodedText.Encode("comments");
    public static readonly JsonEncodedText Tags = JsonEncodedText.Encode("tags");
    public static readonly JsonEncodedText Email = JsonEncodedText.Encode("email");
    public static readonly JsonEncodedText Token = JsonEncodedText.Encode("token");
    public static readonly JsonEncodedText Username = JsonEncodedText.Encode("username");
    public static readonly JsonEncodedText Bio = JsonEncodedText.Encode("bio");
    public static readonly JsonEncodedText Image = JsonEncodedText.Encode("image");
    public static readonly JsonEncodedText Following = JsonEncodedText.Encode("following");
    public static readonly JsonEncodedText Slug = JsonEncodedText.Encode("slug");
    public static readonly JsonEncodedText Title = JsonEncodedText.Encode("title");
    public static readonly JsonEncodedText Description = JsonEncodedText.Encode("description");
    public static readonly JsonEncodedText Body = JsonEncodedText.Encode("body");
    public static readonly JsonEncodedText TagList = JsonEncodedText.Encode("tagList");
    public static readonly JsonEncodedText CreatedAt = JsonEncodedText.Encode("createdAt");
    public static readonly JsonEncodedText UpdatedAt = JsonEncodedText.Encode("updatedAt");
    public static readonly JsonEncodedText Favorited = JsonEncodedText.Encode("favorited");
    public static readonly JsonEncodedText FavoritesCount = JsonEncodedText.Encode("favoritesCount");
    public static readonly JsonEncodedText Author = JsonEncodedText.Encode("author");
    public static readonly JsonEncodedText Id = JsonEncodedText.Encode("id");
    public static readonly JsonEncodedText Errors = JsonEncodedText.Encode("errors");
}
