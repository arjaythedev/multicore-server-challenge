#if DEBUG
using System.Text;

namespace Conduit;

/// <summary>
/// Swagger UI for local testing, compiled into Debug builds only (so `dotnet run` has it, `build.sh` does not).
/// GET /swagger shows the UI (swagger-ui-dist from a CDN); GET /swagger/openapi.json is the hand-written API description.
/// </summary>
internal static class OpenApi
{
  private static readonly byte[] PageBytes = Encoding.UTF8.GetBytes(Page);
  private static readonly byte[] SpecBytes = Encoding.UTF8.GetBytes(Spec);

  /// <summary>Serves /swagger or /swagger/openapi.json.</summary>
  internal static async Task Serve(HttpContext ctx)
  {
    var isPage = ctx.Request.Path.Value == "/swagger";
    var body = isPage ? PageBytes : SpecBytes;
    ctx.Response.StatusCode = 200;
    ctx.Response.ContentType = isPage ? "text/html; charset=utf-8" : "application/json";
    ctx.Response.ContentLength = body.Length;
    await ctx.Response.Body.WriteAsync(body);
  }

  private const string Page = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Conduit API</title>
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css">
        </head>
        <body>
          <div id="swagger-ui"></div>
          <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>
          <script>
            SwaggerUIBundle({ url: "/swagger/openapi.json", dom_id: "#swagger-ui", persistAuthorization: true });
          </script>
        </body>
        </html>
        """;

  // The 19 endpoints of SPEC.md. Authorize with the value "Token <jwt>" (a token comes back from register/login).
  private const string Spec = """
        {
          "openapi": "3.0.3",
          "info": { "title": "Conduit API", "version": "1.0", "description": "RealWorld Conduit for the multicore server challenge. Click Authorize and enter: Token <jwt>" },
          "servers": [ { "url": "/" } ],
          "components": {
            "securitySchemes": {
              "token": { "type": "apiKey", "in": "header", "name": "Authorization", "description": "Format: Token <jwt>" }
            },
            "parameters": {
              "slug": { "name": "slug", "in": "path", "required": true, "schema": { "type": "string" } },
              "username": { "name": "username", "in": "path", "required": true, "schema": { "type": "string" } },
              "limit": { "name": "limit", "in": "query", "schema": { "type": "integer", "minimum": 1, "maximum": 100, "default": 20 } },
              "offset": { "name": "offset", "in": "query", "schema": { "type": "integer", "minimum": 0, "default": 0 } }
            },
            "responses": {
              "Unauthorized": { "description": "Missing or invalid token", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } },
              "Forbidden": { "description": "Not the author", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } },
              "NotFound": { "description": "Not found", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } },
              "Invalid": { "description": "Validation error", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Error" } } } }
            },
            "schemas": {
              "Error": { "type": "object", "properties": { "errors": { "type": "object", "properties": { "body": { "type": "array", "items": { "type": "string" } } } } } },
              "User": { "type": "object", "properties": { "email": { "type": "string" }, "token": { "type": "string" }, "username": { "type": "string" }, "bio": { "type": "string", "nullable": true }, "image": { "type": "string", "nullable": true } } },
              "UserResponse": { "type": "object", "properties": { "user": { "$ref": "#/components/schemas/User" } } },
              "Profile": { "type": "object", "properties": { "username": { "type": "string" }, "bio": { "type": "string", "nullable": true }, "image": { "type": "string", "nullable": true }, "following": { "type": "boolean" } } },
              "ProfileResponse": { "type": "object", "properties": { "profile": { "$ref": "#/components/schemas/Profile" } } },
              "Article": { "type": "object", "properties": { "slug": { "type": "string" }, "title": { "type": "string" }, "description": { "type": "string" }, "body": { "type": "string", "description": "Omitted in lists" }, "tagList": { "type": "array", "items": { "type": "string" } }, "createdAt": { "type": "string" }, "updatedAt": { "type": "string" }, "favorited": { "type": "boolean" }, "favoritesCount": { "type": "integer" }, "author": { "$ref": "#/components/schemas/Profile" } } },
              "ArticleResponse": { "type": "object", "properties": { "article": { "$ref": "#/components/schemas/Article" } } },
              "ArticleList": { "type": "object", "properties": { "articles": { "type": "array", "items": { "$ref": "#/components/schemas/Article" } }, "articlesCount": { "type": "integer", "description": "Capped at 1000" } } },
              "Comment": { "type": "object", "properties": { "id": { "type": "integer" }, "createdAt": { "type": "string" }, "updatedAt": { "type": "string" }, "body": { "type": "string" }, "author": { "$ref": "#/components/schemas/Profile" } } },
              "CommentResponse": { "type": "object", "properties": { "comment": { "$ref": "#/components/schemas/Comment" } } },
              "CommentList": { "type": "object", "properties": { "comments": { "type": "array", "items": { "$ref": "#/components/schemas/Comment" } } } },
              "TagList": { "type": "object", "properties": { "tags": { "type": "array", "items": { "type": "string" } } } },
              "NewUser": { "type": "object", "properties": { "user": { "type": "object", "required": [ "username", "email", "password" ], "properties": { "username": { "type": "string" }, "email": { "type": "string" }, "password": { "type": "string" } } } } },
              "Login": { "type": "object", "properties": { "user": { "type": "object", "required": [ "email", "password" ], "properties": { "email": { "type": "string" }, "password": { "type": "string" } } } } },
              "UpdateUser": { "type": "object", "properties": { "user": { "type": "object", "properties": { "email": { "type": "string" }, "username": { "type": "string" }, "password": { "type": "string" }, "bio": { "type": "string" }, "image": { "type": "string" } } } } },
              "NewArticle": { "type": "object", "properties": { "article": { "type": "object", "required": [ "title", "description", "body" ], "properties": { "title": { "type": "string" }, "description": { "type": "string" }, "body": { "type": "string" }, "tagList": { "type": "array", "items": { "type": "string" } } } } } },
              "UpdateArticle": { "type": "object", "properties": { "article": { "type": "object", "properties": { "title": { "type": "string" }, "description": { "type": "string" }, "body": { "type": "string" } } } } },
              "NewComment": { "type": "object", "properties": { "comment": { "type": "object", "required": [ "body" ], "properties": { "body": { "type": "string" } } } } }
            }
          },
          "paths": {
            "/api/users": {
              "post": { "tags": [ "Users" ], "summary": "Register", "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/NewUser" } } } },
                "responses": { "201": { "description": "Created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UserResponse" } } } }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/users/login": {
              "post": { "tags": [ "Users" ], "summary": "Log in", "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Login" } } } },
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UserResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/user": {
              "get": { "tags": [ "Users" ], "summary": "Current user", "security": [ { "token": [] } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UserResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" } } },
              "put": { "tags": [ "Users" ], "summary": "Update current user", "security": [ { "token": [] } ],
                "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UpdateUser" } } } },
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UserResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/profiles/{username}": {
              "get": { "tags": [ "Profiles" ], "summary": "Get profile (auth optional)", "security": [ {}, { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/username" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ProfileResponse" } } } }, "404": { "$ref": "#/components/responses/NotFound" } } }
            },
            "/api/profiles/{username}/follow": {
              "post": { "tags": [ "Profiles" ], "summary": "Follow", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/username" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ProfileResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "404": { "$ref": "#/components/responses/NotFound" } } },
              "delete": { "tags": [ "Profiles" ], "summary": "Unfollow", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/username" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ProfileResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "404": { "$ref": "#/components/responses/NotFound" } } }
            },
            "/api/articles": {
              "get": { "tags": [ "Articles" ], "summary": "List articles (auth optional). Only the first of tag, author, favorited applies.", "security": [ {}, { "token": [] } ],
                "parameters": [
                  { "name": "tag", "in": "query", "schema": { "type": "string" } },
                  { "name": "author", "in": "query", "schema": { "type": "string" } },
                  { "name": "favorited", "in": "query", "schema": { "type": "string" } },
                  { "$ref": "#/components/parameters/limit" }, { "$ref": "#/components/parameters/offset" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleList" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "422": { "$ref": "#/components/responses/Invalid" } } },
              "post": { "tags": [ "Articles" ], "summary": "Create article", "security": [ { "token": [] } ],
                "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/NewArticle" } } } },
                "responses": { "201": { "description": "Created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/articles/feed": {
              "get": { "tags": [ "Articles" ], "summary": "Feed of followed authors", "security": [ { "token": [] } ],
                "parameters": [ { "$ref": "#/components/parameters/limit" }, { "$ref": "#/components/parameters/offset" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleList" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/articles/{slug}": {
              "get": { "tags": [ "Articles" ], "summary": "Get article (auth optional)", "security": [ {}, { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleResponse" } } } }, "404": { "$ref": "#/components/responses/NotFound" } } },
              "put": { "tags": [ "Articles" ], "summary": "Update own article", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/UpdateArticle" } } } },
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "403": { "$ref": "#/components/responses/Forbidden" }, "404": { "$ref": "#/components/responses/NotFound" }, "422": { "$ref": "#/components/responses/Invalid" } } },
              "delete": { "tags": [ "Articles" ], "summary": "Delete own article", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "responses": { "204": { "description": "Deleted" }, "401": { "$ref": "#/components/responses/Unauthorized" }, "403": { "$ref": "#/components/responses/Forbidden" }, "404": { "$ref": "#/components/responses/NotFound" } } }
            },
            "/api/articles/{slug}/favorite": {
              "post": { "tags": [ "Favorites" ], "summary": "Favorite", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "404": { "$ref": "#/components/responses/NotFound" } } },
              "delete": { "tags": [ "Favorites" ], "summary": "Unfavorite", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ArticleResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "404": { "$ref": "#/components/responses/NotFound" } } }
            },
            "/api/articles/{slug}/comments": {
              "get": { "tags": [ "Comments" ], "summary": "Newest 100 comments (auth optional)", "security": [ {}, { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/CommentList" } } } }, "404": { "$ref": "#/components/responses/NotFound" } } },
              "post": { "tags": [ "Comments" ], "summary": "Add comment", "security": [ { "token": [] } ], "parameters": [ { "$ref": "#/components/parameters/slug" } ],
                "requestBody": { "required": true, "content": { "application/json": { "schema": { "$ref": "#/components/schemas/NewComment" } } } },
                "responses": { "201": { "description": "Created", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/CommentResponse" } } } }, "401": { "$ref": "#/components/responses/Unauthorized" }, "404": { "$ref": "#/components/responses/NotFound" }, "422": { "$ref": "#/components/responses/Invalid" } } }
            },
            "/api/articles/{slug}/comments/{id}": {
              "delete": { "tags": [ "Comments" ], "summary": "Delete own comment", "security": [ { "token": [] } ],
                "parameters": [ { "$ref": "#/components/parameters/slug" }, { "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } } ],
                "responses": { "204": { "description": "Deleted" }, "401": { "$ref": "#/components/responses/Unauthorized" }, "403": { "$ref": "#/components/responses/Forbidden" }, "404": { "$ref": "#/components/responses/NotFound" } } }
            },
            "/api/tags": {
              "get": { "tags": [ "Tags" ], "summary": "All tags, sorted by name",
                "responses": { "200": { "description": "OK", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/TagList" } } } } } }
            }
          }
        }
        """;
}
#endif
