/// The wire types (SPEC.md): response values are written with asdf's
/// `serializeToJson`, request bodies are read with asdf's `deserialize`.
///
/// An absent member and a JSON `null` member both decode to an unset
/// `Nullable`; a present member (including an empty string) decodes to a set
/// `Nullable`. That is exactly the update semantics the spec needs: `null` and
/// absent leave a column unchanged, an empty string clears it.
module conduit.model;

import asdf : serdeOptional;
import std.typecons : Nullable;

// ---------------------------------------------------------------------------
// responses

struct ProfileDto
{
    string username;
    string bio;
    string image;
    bool following;
}

struct UserDto
{
    string username;
    string email;
    string bio;
    string image;
    string token;
}

struct ArticleSummaryDto
{
    string slug;
    string title;
    string description;
    string[] tagList;
    string createdAt;
    string updatedAt;
    bool favorited;
    long favoritesCount;
    ProfileDto author;
}

struct ArticleDto
{
    string slug;
    string title;
    string description;
    string body;
    string[] tagList;
    string createdAt;
    string updatedAt;
    bool favorited;
    long favoritesCount;
    ProfileDto author;
}

struct CommentDto
{
    long id;
    string createdAt;
    string updatedAt;
    string body;
    ProfileDto author;
}

struct ArticleListDto
{
    ArticleSummaryDto[] articles;
    long articlesCount;
}

struct CommentListDto
{
    CommentDto[] comments;
}

struct TagsDto
{
    string[] tags;
}

struct ErrorBodyDto
{
    string[] body;
}

struct ErrorDto
{
    ErrorBodyDto errors;
}

struct UserWrapper
{
    UserDto user;
}

struct ProfileWrapper
{
    ProfileDto profile;
}

struct ArticleWrapper
{
    ArticleDto article;
}

struct CommentWrapper
{
    CommentDto comment;
}

// ---------------------------------------------------------------------------
// requests

struct RegisterUserDto
{
    string username;
    string email;
    string password;
}

struct RegisterDto
{
    RegisterUserDto user;
}

struct LoginUserDto
{
    string email;
    string password;
}

struct LoginDto
{
    LoginUserDto user;
}

struct UserUpdateDto
{
    @serdeOptional Nullable!string email;
    @serdeOptional Nullable!string username;
    @serdeOptional Nullable!string password;
    @serdeOptional Nullable!string bio;
    @serdeOptional Nullable!string image;
}

struct UserUpdateWrapper
{
    UserUpdateDto user;
}

struct ArticleCreateDto
{
    string title;
    string description;
    string body;
    @serdeOptional string[] tagList;
}

struct ArticleCreateWrapper
{
    ArticleCreateDto article;
}

struct ArticleUpdateDto
{
    @serdeOptional Nullable!string title;
    @serdeOptional Nullable!string description;
    @serdeOptional Nullable!string body;
}

struct ArticleUpdateWrapper
{
    ArticleUpdateDto article;
}

struct CommentCreateDto
{
    string body;
}

struct CommentCreateWrapper
{
    CommentCreateDto comment;
}
