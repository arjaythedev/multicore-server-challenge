<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Worker;

use Attribute;

/**
 * Declares that a service keeps state on purpose for the life of its worker (an open connection, prepared
 * statements) and says why; the rule against mutable service state accepts it in place of a reset.
 */
#[Attribute(Attribute::TARGET_CLASS)]
final readonly class SurvivesRequests
{
    public function __construct(public string $reason)
    {
    }
}
