//Auth
export type AuthContext = {
  viewerId: bigint; // 0n means anonymous
  token: string | null; // the exact presented token
};

// Users
export type NewUserBody = {
  username: string;
  email: string;
  password: string;
};
export type ResponseUser = {
  email: string;
  token: string;
  username: string;
  bio: string | null;
  image: string | null;
};

//Profile
export type ProfileResponse = {
  id: bigint;
  username: string;
  bio: string;
  image: string;
  following: boolean;
};

//Article
export type Article = {
  slug: string;
  title: string;
  description: string;
  body: string;
  tagList: string[];
  createdAt: Date;
  updatedAt: Date;
  favorited: boolean;
  favoritesCount: number;
  author: ProfileResponse;
};

export type ArticleResponse = {
  articles: Article[];
  articlesCount: number;
};
