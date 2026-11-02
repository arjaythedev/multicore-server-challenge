-- An article in a list: the same object without "body".
jsonb_build_object(
  'slug', a.slug, 'title', a.title, 'description', a.description,
{{_article_tail}})
