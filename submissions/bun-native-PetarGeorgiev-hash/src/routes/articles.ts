import { authenticate } from "../auth/auth";
import {
  addFavorite,
  createArticle,
  deleteArticle,
  deleteComment,
  getArticleIdBySlug,
  getArticleOwnership,
  countFeed,
  getArticles,
  getArticlesAuthor,
  getArticlesBySlug,
  getArticlesCount,
  getArticlesCountAuthor,
  getArticlesCountFavorites,
  getArticlesCountTag,
  getArticlesFavorites,
  getArticlesTag,
  getCommentAuthor,
  getComments,
  getFeed,
  insertComment,
  removeFavorite,
  updateArticle,
} from "../db/sql";
import {
  BadBody,
  errorResponse,
  getLimitAndOffset,
  optString,
  readWrapper,
  reqString,
  res,
} from "../utils/utils";

function toArticle(row: any, includeBody = false) {
  const article = {
    slug: row.slug,
    title: row.title,
    description: row.description,
    tagList: row.tag_list ?? [],
    createdAt: new Date(row.created_at).toISOString(),
    updatedAt: new Date(row.updated_at).toISOString(),
    favorited: row.favorited,
    favoritesCount: Number(row.favorites_count),
    author: {
      username: row.username,
      bio: row.bio,
      image: row.image,
      following: row.following,
    },
  };
  return includeBody ? { ...article, body: row.body } : article;
}

function toComment(row: any, following = row.following) {
  return {
    id: Number(row.id),
    body: row.body,
    createdAt: new Date(row.created_at).toISOString(),
    updatedAt: new Date(row.updated_at).toISOString(),
    author: {
      username: row.username,
      bio: row.bio,
      image: row.image,
      following,
    },
  };
}

export const articleRoute = {
  POST: async (req: Request): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;

    let title: string, description: string, body: string;
    let tagList: string[] = [];
    try {
      const article = await readWrapper(req, "article");
      title = reqString(article, "title");
      description = reqString(article, "description");
      body = reqString(article, "body");
      const rawTags = article.tagList;
      if (rawTags !== undefined && rawTags !== null) {
        if (
          !Array.isArray(rawTags) ||
          !rawTags.every((tag) => typeof tag === "string" && tag !== "")
        ) {
          return errorResponse(422, "Invalid tagList");
        }
        tagList = rawTags;
      }
    } catch (error) {
      if (error instanceof BadBody) {
        return errorResponse(422, "Invalid request body");
      }
      throw error;
    }

    const created = await createArticle(
      viewerId,
      title,
      description,
      body,
      tagList,
    );
    const [row] = await getArticlesBySlug(viewerId, created.slug);
    return res({ article: toArticle(row, true) }, 201);
  },
  GET: async (req: Bun.BunRequest): Promise<Response> => {
    const auth = await authenticate(req, false);
    if (auth instanceof Response) return auth;

    const { viewerId } = auth;
    const params = new URL(req.url).searchParams;
    const limitAndOffset = getLimitAndOffset(params);
    if (limitAndOffset instanceof Response) return limitAndOffset;
    const { limit, offset } = limitAndOffset;

    const tag = params.get("tag");
    const author = params.get("author");
    const favorited = params.get("favorited");

    let rows;
    let countRow;

    if (tag) {
      rows = await getArticlesTag(tag, viewerId, limit, offset);
      [countRow] = await getArticlesCountTag(tag);
    } else if (author) {
      rows = await getArticlesAuthor(author, viewerId, limit, offset);
      [countRow] = await getArticlesCountAuthor(author);
    } else if (favorited) {
      rows = await getArticlesFavorites(favorited, viewerId, limit, offset);
      [countRow] = await getArticlesCountFavorites(favorited);
    } else {
      rows = await getArticles(viewerId, limit, offset);
      [countRow] = await getArticlesCount();
    }
    return res(
      {
        articles: rows.map(toArticle),
        articlesCount: Number(countRow.count),
      },
      200,
    );
  },
};

export const articleRouteSlug = {
  GET: async (
    req: Bun.BunRequest<"/api/articles/:slug">,
  ): Promise<Response> => {
    const auth = await authenticate(req, false);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;
    const [row] = await getArticlesBySlug(viewerId, slug);
    if (!row) return errorResponse(404, "Not Found");
    return res({ article: toArticle(row, true) }, 200);
  },
  PUT: async (
    req: Bun.BunRequest<"/api/articles/:slug">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;

    let title: string | null, description: string | null, body: string | null;
    try {
      const article = await readWrapper(req, "article");
      title = optString(article, "title", true);
      description = optString(article, "description", true);
      body = optString(article, "body", true);
    } catch (error) {
      if (error instanceof BadBody) {
        return errorResponse(422, "Invalid request body");
      }
      throw error;
    }

    const [ownedArticle] = await getArticleOwnership(slug);
    if (!ownedArticle) return errorResponse(404, "Not Found");
    if (BigInt(ownedArticle.author_id) !== viewerId) {
      return errorResponse(403, "Forbidden");
    }

    const [updated] = await updateArticle(
      ownedArticle.id,
      title,
      description,
      body,
    );
    const [row] = await getArticlesBySlug(viewerId, updated.slug);
    return res({ article: toArticle(row, true) }, 200);
  },
  DELETE: async (
    req: Bun.BunRequest<"/api/articles/:slug">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;
    const [article] = await getArticleOwnership(slug);
    if (!article) return errorResponse(404, "Not Found");
    if (BigInt(article.author_id) !== viewerId) {
      return errorResponse(403, "Forbidden");
    }
    await deleteArticle(article.id);
    return new Response(null, { status: 204 });
  },
};

export const articleRouteFeed = {
  GET: async (req: Bun.BunRequest<"/api/articles/feed">): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const params = new URL(req.url).searchParams;
    const limitAndOffset = getLimitAndOffset(params);
    if (limitAndOffset instanceof Response) return limitAndOffset;
    const { limit, offset } = limitAndOffset;
    const row = await getFeed(viewerId, limit, offset);
    const [countRow] = await countFeed(viewerId);
    return res(
      {
        articles: row.map(toArticle),
        articlesCount: Number(countRow.count),
      },
      200,
    );
  },
};

export const articleFavoriteRoute = {
  POST: async (
    req: Bun.BunRequest<"/api/articles/:slug/favorite">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;
    const [article] = await getArticleIdBySlug(slug);
    if (!article) return errorResponse(404, "Not Found");

    await addFavorite(viewerId, article.id);
    const [row] = await getArticlesBySlug(viewerId, slug);
    return res({ article: toArticle(row, true) }, 200);
  },
  DELETE: async (
    req: Bun.BunRequest<"/api/articles/:slug/favorite">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;
    const [article] = await getArticleIdBySlug(slug);
    if (!article) return errorResponse(404, "Not Found");

    await removeFavorite(viewerId, article.id);
    const [row] = await getArticlesBySlug(viewerId, slug);
    return res({ article: toArticle(row, true) }, 200);
  },
};

export const articleCommentsRoute = {
  GET: async (
    req: Bun.BunRequest<"/api/articles/:slug/comments">,
  ): Promise<Response> => {
    const auth = await authenticate(req, false);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug } = req.params;
    const [article] = await getArticleIdBySlug(slug);
    if (!article) return errorResponse(404, "Not Found");

    const rows = await getComments(viewerId, article.id);
    return res({ comments: rows.map((row: any) => toComment(row)) }, 200);
  },
  POST: async (
    req: Bun.BunRequest<"/api/articles/:slug/comments">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    let body: string;
    try {
      const comment = await readWrapper(req, "comment");
      body = reqString(comment, "body");
    } catch (error) {
      if (error instanceof BadBody) return errorResponse(422, "Invalid request body");
      throw error;
    }

    const { slug } = req.params;
    const [article] = await getArticleIdBySlug(slug);
    if (!article) return errorResponse(404, "Not Found");

    const [row] = await insertComment(article.id, viewerId, body);
    return res({ comment: toComment(row, false) }, 201);
  },
};

export const articleCommentRoute = {
  DELETE: async (
    req: Bun.BunRequest<"/api/articles/:slug/comments/:id">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { slug, id } = req.params;
    if (!/^[0-9]+$/.test(id)) return errorResponse(404, "Not Found");
    const commentId = BigInt(id);
    if (commentId > 9223372036854775807n) {
      return errorResponse(404, "Not Found");
    }

    const [comment] = await getCommentAuthor(slug, commentId);
    if (!comment) return errorResponse(404, "Not Found");
    if (BigInt(comment.author_id) !== viewerId) {
      return errorResponse(403, "Forbidden");
    }
    await deleteComment(commentId);
    return new Response(null, { status: 204 });
  },
};
