-- POST /api/articles, 4/6
INSERT INTO tags (name) SELECT DISTINCT unnest(:tag_list::text[]) ON CONFLICT (name) DO NOTHING
