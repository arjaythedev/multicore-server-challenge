jsonb_build_object('user', jsonb_build_object('email', u.email, 'token', u.token, 'username', u.username,
                                              'bio', u.bio, 'image', u.image))::text
