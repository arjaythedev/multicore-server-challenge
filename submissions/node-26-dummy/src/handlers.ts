import type { IncomingMessage, ServerResponse } from "node:http";

export interface RequestContext {
  readonly request: IncomingMessage;
  readonly response: ServerResponse;
  readonly url: URL;
  readonly params: Readonly<Record<string, string>>;
}

export type Handler = (context: RequestContext) => void | Promise<void>;

export function sendJson(
  response: ServerResponse,
  status: number,
  body: unknown,
): void {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}

export function sendError(
  response: ServerResponse,
  status: number,
  message: string,
): void {
  sendJson(response, status, { errors: { body: [message] } });
}

const placeholder = (name: string): Handler => ({ response }) => {
  sendError(response, 501, `not implemented: ${name}`);
};

// Users and authentication
// POST /api/users -> 201 { user }
export const registerUser: Handler = placeholder("registerUser");

// POST /api/users/login -> 200 { user }
export const loginUser: Handler = placeholder("loginUser");

// GET /api/user -> 200 { user }
export const getCurrentUser: Handler = placeholder("getCurrentUser");

// PUT /api/user -> 200 { user }
export const updateCurrentUser: Handler = placeholder("updateCurrentUser");

// Profiles
// GET /api/profiles/:username -> 200 { profile }
export const getProfile: Handler = placeholder("getProfile");

// POST /api/profiles/:username/follow -> 200 { profile }
export const followProfile: Handler = placeholder("followProfile");

// DELETE /api/profiles/:username/follow -> 200 { profile }
export const unfollowProfile: Handler = placeholder("unfollowProfile");

// Articles
// GET /api/articles -> 200 { articles, articlesCount }
export const listArticles: Handler = placeholder("listArticles");

// GET /api/articles/feed -> 200 { articles, articlesCount }
export const getArticleFeed: Handler = placeholder("getArticleFeed");

// GET /api/articles/:slug -> 200 { article }
export const getArticle: Handler = placeholder("getArticle");

// POST /api/articles -> 201 { article }
export const createArticle: Handler = placeholder("createArticle");

// PUT /api/articles/:slug -> 200 { article }
export const updateArticle: Handler = placeholder("updateArticle");

// DELETE /api/articles/:slug -> 204
export const deleteArticle: Handler = placeholder("deleteArticle");

// Favorites
// POST /api/articles/:slug/favorite -> 200 { article }
export const favoriteArticle: Handler = placeholder("favoriteArticle");

// DELETE /api/articles/:slug/favorite -> 200 { article }
export const unfavoriteArticle: Handler = placeholder("unfavoriteArticle");

// Comments
// GET /api/articles/:slug/comments -> 200 { comments }
export const listComments: Handler = placeholder("listComments");

// POST /api/articles/:slug/comments -> 201 { comment }
export const createComment: Handler = placeholder("createComment");

// DELETE /api/articles/:slug/comments/:id -> 204
export const deleteComment: Handler = placeholder("deleteComment");

// Tags are also the process health check. Replace the empty array with the
// sorted tag names read from PostgreSQL when implementing this handler.
// GET /api/tags -> 200 { tags }
export const listTags: Handler = ({ response }) => {
  sendJson(response, 200, { tags: [] });
};
