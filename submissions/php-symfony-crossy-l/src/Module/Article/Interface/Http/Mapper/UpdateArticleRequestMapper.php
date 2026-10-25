<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Command\UpdateArticle\UpdateArticleCommand;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"article": {...}} with any of title, description and body, each a non-empty string. An absent or
 * null field is left unchanged.
 */
final class UpdateArticleRequestMapper
{
    public function toCommand(Request $request, CallerContext $caller, string $slug): UpdateArticleCommand
    {
        $article = JsonBody::unwrap($request->getContent(), 'article');

        return new UpdateArticleCommand(
            caller: $caller,
            slug: $slug,
            title: $article->optionalNonEmptyString('title'),
            description: $article->optionalNonEmptyString('description'),
            body: $article->optionalNonEmptyString('body'),
        );
    }
}
