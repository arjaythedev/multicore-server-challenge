package server

// Resolve the username within the committed generic write cohort instead of
// acquiring a separate connection in the HTTP handler. Off for comparisons.
var writeFollowLookup = envOr("WRITE_FOLLOW_LOOKUP", "0") == "1"

// The response profile and write use the same target snapshot. As with slug
// writes, scanWrite publishes these provisional rows only after batch commit.
const insertFollowByUsernameSQL = `WITH target AS MATERIALIZED
 (SELECT id,username,bio,image FROM users WHERE username=$2),
 written AS (INSERT INTO follows (follower_id,followee_id)
 SELECT $1,id FROM target ON CONFLICT DO NOTHING)
 SELECT username,bio,image FROM target`

const deleteFollowByUsernameSQL = `WITH target AS MATERIALIZED
 (SELECT id,username,bio,image FROM users WHERE username=$2),
 written AS (DELETE FROM follows
 WHERE follower_id=$1 AND followee_id IN (SELECT id FROM target))
 SELECT username,bio,image FROM target`

func followByUsernameStatement(insert bool) string {
	if insert {
		return insertFollowByUsernameSQL
	}
	return deleteFollowByUsernameSQL
}
