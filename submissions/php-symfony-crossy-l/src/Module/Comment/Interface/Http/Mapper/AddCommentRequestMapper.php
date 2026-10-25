<?php

declare(strict_types=1);

namespace App\Module\Comment\Interface\Http\Mapper;

use App\Module\Comment\Application\Command\AddComment\AddCommentCommand;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"comment": {"body"}}, a non-empty string. The body is checked before the article is looked up.
 */
final class AddCommentRequestMapper
{
    public function toCommand(Request $request, CallerContext $caller, string $slug): AddCommentCommand
    {
        $comment = JsonBody::unwrap($request->getContent(), 'comment');

        return new AddCommentCommand(caller: $caller, slug: $slug, body: $comment->requiredString('body'));
    }
}
