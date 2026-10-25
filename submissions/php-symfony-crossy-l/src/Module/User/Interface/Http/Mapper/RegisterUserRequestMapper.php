<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Command\RegisterUser\RegisterUserCommand;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"user": {"username", "email", "password"}}, all three non-empty strings.
 */
final class RegisterUserRequestMapper
{
    public function toCommand(Request $request): RegisterUserCommand
    {
        $user = JsonBody::unwrap($request->getContent(), 'user');

        return new RegisterUserCommand(
            username: $user->requiredString('username'),
            email: $user->requiredString('email'),
            password: $user->requiredString('password'),
        );
    }
}
