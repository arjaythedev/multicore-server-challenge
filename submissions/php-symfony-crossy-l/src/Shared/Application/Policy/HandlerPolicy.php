<?php

declare(strict_types=1);

namespace App\Shared\Application\Policy;

use App\Shared\Domain\Security\CallerContext;

/**
 * Answers whether a kind of caller may do a kind of thing. It sees the caller and nothing else:
 * whether the caller stands in the right relationship to one particular record is decided where
 * that record is read.
 */
interface HandlerPolicy
{
    public function authorize(CallerContext $caller): void;
}
