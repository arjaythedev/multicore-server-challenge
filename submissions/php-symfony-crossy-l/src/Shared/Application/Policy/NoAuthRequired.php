<?php

declare(strict_types=1);

namespace App\Shared\Application\Policy;

use Attribute;

/**
 * Marks a handler that serves every caller, anonymous ones included, and says why.
 */
#[Attribute(Attribute::TARGET_CLASS)]
final readonly class NoAuthRequired
{
    public function __construct(public string $reason)
    {
    }
}
