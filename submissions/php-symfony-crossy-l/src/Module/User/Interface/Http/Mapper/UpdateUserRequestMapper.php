<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Command\UpdateUser\UpdateUserCommand;
use App\Shared\Domain\Security\CallerContext;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"user": {...}} with any of email, username, password (non-empty strings), bio and image (strings,
 * which may be empty). An absent or null field is left unchanged.
 */
final class UpdateUserRequestMapper
{
    public function toCommand(Request $request, CallerContext $caller): UpdateUserCommand
    {
        $user = JsonBody::unwrap($request->getContent(), 'user');

        return new UpdateUserCommand(
            caller: $caller,
            email: $user->optionalNonEmptyString('email'),
            username: $user->optionalNonEmptyString('username'),
            password: $user->optionalNonEmptyString('password'),
            bio: $user->optionalString('bio'),
            image: $user->optionalString('image'),
        );
    }
}
