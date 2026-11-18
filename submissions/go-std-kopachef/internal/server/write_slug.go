package server

// Only generic write cohorts use this experiment. Favorite-specific batching
// and unbatched handlers retain their existing lookup/write sequence.
var writeSlugLookup = envOr("WRITE_SLUG_LOOKUP", "0") == "1"

// The target is shared by the write and its ID result in one statement snapshot.
// A data-modifying CTE executes even without RETURNING/referencing its output.
// The ID remains provisional until writeQueue consumes the implicit commit.
const insertFavoriteBySlugSQL = `WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug=$2),
 written AS (INSERT INTO favorites (user_id,article_id)
 SELECT $1,id FROM target ON CONFLICT DO NOTHING)
 SELECT id FROM target`

const deleteFavoriteBySlugSQL = `WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug=$2),
 written AS (DELETE FROM favorites
 WHERE user_id=$1 AND article_id IN (SELECT id FROM target))
 SELECT id FROM target`

func favoriteBySlugStatement(insert bool) string {
	if insert {
		return insertFavoriteBySlugSQL
	}
	return deleteFavoriteBySlugSQL
}

const insertCommentByIDSQL = `WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`

const insertCommentBySlugSQL = `WITH c AS (INSERT INTO comments (article_id,author_id,body)
 SELECT id,$2,$3 FROM articles WHERE slug=$1
 RETURNING id,body,created_at,updated_at,author_id)
 SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image
 FROM c JOIN users u ON u.id=c.author_id`
