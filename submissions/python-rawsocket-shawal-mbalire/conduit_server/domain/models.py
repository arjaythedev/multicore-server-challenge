from dataclasses import dataclass, field
from typing import List, Optional


@dataclass(frozen=True)
class ProfileData:
    username: str
    bio: Optional[str]
    image: Optional[str]
    following: bool


@dataclass(frozen=True)
class ProfileResponse:
    profile: ProfileData


@dataclass(frozen=True)
class UserData:
    email: str
    token: str
    username: str
    bio: Optional[str]
    image: Optional[str]


@dataclass(frozen=True)
class UserResponse:
    user: UserData


@dataclass(frozen=True)
class ArticleData:
    slug: str
    title: str
    description: str
    body: Optional[str]
    tagList: List[str]
    createdAt: str
    updatedAt: str
    favorited: bool
    favoritesCount: int
    author: ProfileData


@dataclass(frozen=True)
class SingleArticleResponse:
    article: ArticleData


@dataclass(frozen=True)
class ArticlesResponse:
    articles: List[ArticleData]
    articlesCount: int


@dataclass(frozen=True)
class CommentData:
    id: int
    createdAt: str
    updatedAt: str
    body: str
    author: ProfileData


@dataclass(frozen=True)
class SingleCommentResponse:
    comment: CommentData


@dataclass(frozen=True)
class CommentsResponse:
    comments: List[CommentData]


@dataclass(frozen=True)
class TagsResponse:
    tags: List[str] = field(default_factory=list)


@dataclass(frozen=True)
class Empty:
    """Marker for 204 responses."""
