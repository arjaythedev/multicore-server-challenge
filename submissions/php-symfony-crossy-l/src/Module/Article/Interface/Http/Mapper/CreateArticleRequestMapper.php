<?php

declare(strict_types=1);

namespace App\Module\Article\Interface\Http\Mapper;

use App\Module\Article\Application\Command\CreateArticle\CreateArticleCommand;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"article": {"title", "description", "body", "tagList"?}}: three non-empty strings, and optionally an
 * array of non-empty strings.
 */
final class CreateArticleRequestMapper
{
    public function toCommand(Request $request, CallerContext $caller): CreateArticleCommand
    {
        $article = JsonBody::unwrap($request->getContent(), 'article');

        return new CreateArticleCommand(
            caller: $caller,
            title: $article->requiredString('title'),
            description: $article->requiredString('description'),
            body: $article->requiredString('body'),
            tagList: $article->optionalStringList('tagList'),
        );
    }
}
