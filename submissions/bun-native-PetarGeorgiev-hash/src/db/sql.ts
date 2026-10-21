import { db } from "./db";

//Tags
export const getTags = () => db`SELECT name FROM tags ORDER BY name`;

//Users
export const insertUser = (
  username: string,
  email: string,
  password_hash: string,
) =>
  db`INSERT INTO users (username, email, password_hash) VALUES (${username}, ${email}, ${password_hash})
RETURNING id, username, email, bio, image`;

export const getUser = (email: string) =>
  db`SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ${email}`;

export const getUserById = (viewerId: bigint) =>
  db`SELECT id, username, email, bio, image FROM users WHERE id = ${viewerId}`;

export const updateUser = (
  userId: bigint,
  email: string | null,
  username: string | null,
  passwordHash: string | null,
  bio: string | null,
  image: string | null,
) => db`
  UPDATE users
     SET email = COALESCE(${email}, email),
         username = COALESCE(${username}, username),
         password_hash = COALESCE(${passwordHash}, password_hash),
         bio = COALESCE(${bio}, bio),
         image = COALESCE(${image}, image)
   WHERE id = ${userId}
  RETURNING id, username, email, bio, image
`;

//Profiles
export const getProfile = (
  viewerId: bigint,
  username: string,
) => db`SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ${viewerId} AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = ${username}`;

export const checkProfile = (username: string) =>
  db`SELECT id, username, bio, image FROM users WHERE username = ${username}`;

export const followProfile = (viewerId: bigint, targetId: bigint) =>
  db`INSERT INTO follows (follower_id, followee_id) VALUES (${viewerId}, ${targetId}) ON CONFLICT DO NOTHING`;

export const unFollowProfile = (viewerId: bigint, targetId: bigint) =>
  db`DELETE FROM follows WHERE follower_id = ${viewerId} AND followee_id = ${targetId}`;

export const getArticles = (
  viewerId: bigint,
  limit: number,
  offset: bigint,
) => db`
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         ARRAY(
           SELECT t.name
           FROM article_tags at
           JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = a.id
           ORDER BY t.name
         ) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (
           SELECT 1 FROM favorites f
           WHERE f.article_id = a.id AND f.user_id = ${viewerId}
         ) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id
         ) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  ORDER BY a.id DESC
  LIMIT ${limit} OFFSET ${offset}
`;

export const getArticlesCount = () =>
  db`SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s`;

export const getArticlesTag = (
  tag: string,
  viewerId: bigint,
  limit: number,
  offset: bigint,
) => db`
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         ARRAY(
           SELECT t.name
           FROM article_tags at
           JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = a.id
           ORDER BY t.name
         ) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (
           SELECT 1 FROM favorites f
           WHERE f.article_id = a.id AND f.user_id = ${viewerId}
         ) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id
         ) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ${tag}) ORDER BY at.article_id DESC LIMIT ${limit} OFFSET ${offset})
  ORDER BY a.id DESC
`;
export const getArticlesCountTag = (tag: string) =>
  db`SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ${tag}) LIMIT 1000) s`;

export const getArticlesAuthor = (
  authorUsername: string,
  viewerId: bigint,
  limit: number,
  offset: bigint,
) => db`
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         ARRAY(
           SELECT t.name
           FROM article_tags at
           JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = a.id
           ORDER BY t.name
         ) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (
           SELECT 1 FROM favorites f
           WHERE f.article_id = a.id AND f.user_id = ${viewerId}
         ) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id
         ) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = ${authorUsername})
  ORDER BY a.id DESC LIMIT ${limit} OFFSET ${offset}`;

export const getArticlesCountAuthor = (authorUsername: string) =>
  db`SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ${authorUsername}) LIMIT 1000) s`;

export const getArticlesFavorites = (
  favorite: string,
  viewerId: bigint,
  limit: number,
  offset: bigint,
) => db`
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         ARRAY(
           SELECT t.name
           FROM article_tags at
           JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = a.id
           ORDER BY t.name
         ) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (
           SELECT 1 FROM favorites f
           WHERE f.article_id = a.id AND f.user_id = ${viewerId}
         ) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id
         ) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ${favorite}) ORDER BY f.article_id DESC LIMIT ${limit} OFFSET ${offset}) ORDER BY a.id DESC`;

export const getArticlesCountFavorites = (favorites: string) =>
  db`SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ${favorites}) LIMIT 1000) s`;

export const getArticleIdBySlug = (slug: string) =>
  db`SELECT id FROM articles WHERE slug = ${slug}`;

export const getArticleOwnership = (slug: string) =>
  db`SELECT id, author_id FROM articles WHERE slug = ${slug}`;

export const createArticle = async (
  viewerId: bigint,
  title: string,
  description: string,
  body: string,
  tagList: string[],
) =>
  db.begin(async (tx) => {
    const [article] = await tx`
      INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id,
             trim(both '-' from lower(regexp_replace(${title}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
             ${viewerId}, ${title}, ${description}, ${body}
      FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
      RETURNING id, slug
    `;
    for (const tag of tagList) {
      await tx`INSERT INTO tags (name) VALUES (${tag}) ON CONFLICT (name) DO NOTHING`;
      await tx`
        INSERT INTO article_tags (article_id, tag_id)
        SELECT ${article.id}, id FROM tags WHERE name = ${tag}
        ON CONFLICT DO NOTHING
      `;
    }
    return article;
  });

export const updateArticle = (
  articleId: bigint,
  title: string | null,
  description: string | null,
  body: string | null,
) => db`
  UPDATE articles
  SET title = COALESCE(${title}, title),
      description = COALESCE(${description}, description),
      body = COALESCE(${body}, body),
      slug = CASE
        WHEN ${title}::text IS NULL THEN slug
        ELSE trim(both '-' from lower(regexp_replace(${title}, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id
      END,
      updated_at = now()
  WHERE id = ${articleId}
  RETURNING slug
`;

export const deleteArticle = (articleId: bigint) =>
  db`DELETE FROM articles WHERE id = ${articleId}`;

export const addFavorite = (viewerId: bigint, articleId: bigint) =>
  db`INSERT INTO favorites (user_id, article_id) VALUES (${viewerId}, ${articleId}) ON CONFLICT DO NOTHING`;

export const removeFavorite = (viewerId: bigint, articleId: bigint) =>
  db`DELETE FROM favorites WHERE user_id = ${viewerId} AND article_id = ${articleId}`;

export const getArticlesBySlug = (viewerId: bigint, slug: string) => db`
  SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
         ARRAY(
           SELECT t.name FROM article_tags at
           JOIN tags t ON t.id = at.tag_id
           WHERE at.article_id = a.id ORDER BY t.name
         ) AS tag_list,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
         EXISTS (
           SELECT 1 FROM favorites f
           WHERE f.article_id = a.id AND f.user_id = ${viewerId}
         ) AS favorited,
         u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id
         ) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  WHERE a.slug = ${slug}
`;

export const getComments = (viewerId: bigint, articleId: bigint) => db`
  SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
         EXISTS (
           SELECT 1 FROM follows fo
           WHERE fo.follower_id = ${viewerId} AND fo.followee_id = c.author_id
         ) AS following
  FROM comments c
  JOIN users u ON u.id = c.author_id
  WHERE c.article_id = ${articleId}
  ORDER BY c.created_at DESC, c.id DESC
  LIMIT 100
`;

export const insertComment = (
  articleId: bigint,
  viewerId: bigint,
  body: string,
) => db`
  WITH c AS (
    INSERT INTO comments (article_id, author_id, body)
    VALUES (${articleId}, ${viewerId}, ${body})
    RETURNING id, body, created_at, updated_at, author_id
  )
  SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c
  JOIN users u ON u.id = c.author_id
`;

export const getCommentAuthor = (slug: string, commentId: bigint) => db`
  SELECT c.author_id
  FROM comments c
  JOIN articles a ON a.id = c.article_id
  WHERE c.id = ${commentId} AND a.slug = ${slug}
`;

export const deleteComment = (commentId: bigint) =>
  db`DELETE FROM comments WHERE id = ${commentId}`;

export const getFeed = (viewerId: bigint, limit: number, offset: bigint) =>
  db`SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ${viewerId}) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ${viewerId} AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
   WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (${limit}::int + ${offset}::int)) x WHERE fo.follower_id = ${viewerId} ORDER BY x.id DESC LIMIT ${limit} OFFSET ${offset})
   ORDER BY a.id DESC`;

export const countFeed = (viewerId: bigint) =>
  db`SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ${viewerId}) LIMIT 1000) s`;
