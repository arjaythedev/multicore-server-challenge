<?php

declare(strict_types=1);

namespace App\Module\Article\Domain\Repository;

use App\Module\Article\Domain\Model\ArticleAuthorship;
use App\Module\Article\Domain\Model\ArticleChanges;
use App\Module\Article\Domain\Model\NewArticle;
use App\Module\Article\Domain\View\ArticleView;

/**
 * One article at a time. Viewer 0, the anonymous one, has favorited nothing and follows nobody.
 */
interface ArticleRepositoryInterface
{
    public function findBySlug(string $slug, int $viewerId): ?ArticleView;

    public function findById(int $id, int $viewerId): ?ArticleView;

    public function findIdBySlug(string $slug): ?int;

    public function findAuthorshipBySlug(string $slug): ?ArticleAuthorship;

    /**
     * Writes the article, its new tags and its tag links together, and returns its id.
     */
    public function add(NewArticle $article): int;

    public function update(int $id, ArticleChanges $changes): void;

    /**
     * Deletes the article with its tag links, favorites and comments.
     */
    public function delete(int $id): void;
}
