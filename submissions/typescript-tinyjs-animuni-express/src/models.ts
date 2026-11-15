export type ProfileRow = { username: string; bio: string | null; image: string | null; following?: boolean };
export type UserRow = ProfileRow & { id: string; email: string; password_hash?: string };
export type ArticleRow = ProfileRow & {
  slug: string; title: string; description: string; body?: string; tag_list: string[];
  created_at: Date; updated_at: Date; favorited: boolean; favorites_count: string;
};
export type CommentRow = ProfileRow & { id: string; body: string; created_at: Date; updated_at: Date };

export const profile = (row: ProfileRow) => ({
  username: row.username, bio: row.bio, image: row.image, following: row.following ?? false,
});

export const user = (row: UserRow, token: string) => ({
  email: row.email, token, username: row.username, bio: row.bio, image: row.image,
});

export const article = (row: ArticleRow) => ({
  slug: row.slug, title: row.title, description: row.description,
  ...(row.body === undefined ? {} : { body: row.body }),
  tagList: row.tag_list,
  createdAt: row.created_at.toISOString(), updatedAt: row.updated_at.toISOString(),
  favorited: row.favorited, favoritesCount: Number(row.favorites_count), author: profile(row),
});

export const comment = (row: CommentRow) => ({
  id: Number(row.id), body: row.body,
  createdAt: row.created_at.toISOString(), updatedAt: row.updated_at.toISOString(), author: profile(row),
});
