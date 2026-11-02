jsonb_build_object('id', c.id, 'createdAt', to_char(c.created_at AT TIME ZONE 'UTC', {{_ts}}),
                   'updatedAt', to_char(c.updated_at AT TIME ZONE 'UTC', {{_ts}}), 'body', c.body,
                   'author', jsonb_build_object('username', u.username, 'bio', u.bio, 'image', u.image,
                                                'following', c.following))
