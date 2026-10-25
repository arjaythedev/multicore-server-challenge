<?php

declare(strict_types=1);

namespace App\Shared\Application\Policy;

use Attribute;

/**
 * Names the policy a command or query handler asks about the caller before it delegates.
 */
#[Attribute(Attribute::TARGET_CLASS)]
final readonly class AuthorizationPolicy
{
    /**
     * @param class-string<HandlerPolicy> $policyClass
     */
    public function __construct(public string $policyClass)
    {
    }
}
