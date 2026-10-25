<?php

declare(strict_types=1);

namespace App\Module\Article\Application\Command\UpdateArticle;

use App\Shared\Domain\Security\CallerContext;

/**
 * A null field is left unchanged.
 */
final readonly class UpdateArticleCommand
{
    public function __construct(
        public CallerContext $caller,
        public string $slug,
        public ?string $title,
        public ?string $description,
        public ?string $body,
    ) {
    }
}
