<?php

declare(strict_types=1);

namespace App\Module\User\Interface\Http\Mapper;

use App\Module\User\Application\Query\LogIn\LogInQuery;
use App\Shared\Interface\Http\Request\JsonBody;
use Symfony\Component\HttpFoundation\Request;

/**
 * {"user": {"email", "password"}}, both non-empty strings.
 */
final class LogInRequestMapper
{
    public function toQuery(Request $request): LogInQuery
    {
        $user = JsonBody::unwrap($request->getContent(), 'user');

        return new LogInQuery(
            email: $user->requiredString('email'),
            password: $user->requiredString('password'),
        );
    }
}
