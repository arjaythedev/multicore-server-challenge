jsonb_build_object(
  'slug', a.slug, 'title', a.title, 'description', a.description, 'body', a.body,
{{_article_tail}})
