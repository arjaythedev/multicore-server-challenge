<?php

declare(strict_types=1);

namespace App\Module\Comment\Domain\Repository;

use App\Module\Comment\Domain\Model\CommentAuthorship;
use App\Module\Comment\Domain\Model\NewComment;
use App\Module\Comment\Domain\View\CommentView;
use App\Module\Comment\Domain\View\CommentViewList;

interface CommentRepositoryInterface
{
    /**
     * The id of the article the comments hang off.
     */
    public function findArticleIdBySlug(string $slug): ?int;

    /**
     * The newest 100 comments of the article with this slug, newest first, or null when there is no such
     * article. Viewer 0, the anonymous one, follows nobody.
     */
    public function findNewestBySlug(string $slug, int $viewerId): ?CommentViewList;

    /**
     * Writes the comment and returns it as its author sees it.
     */
    public function add(NewComment $comment): CommentView;

    /**
     * The comment, if it exists and hangs off the article with this slug.
     */
    public function findAuthorshipOnArticle(int $commentId, string $slug): ?CommentAuthorship;

    public function delete(int $commentId): void;
}
