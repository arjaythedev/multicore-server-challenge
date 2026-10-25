<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Response;

/**
 * {"article": Article}
 */
final readonly class ArticleEnvelopeResponse
{
    public function __construct(
        public ArticleResponse $article,
    ) {
    }
}
