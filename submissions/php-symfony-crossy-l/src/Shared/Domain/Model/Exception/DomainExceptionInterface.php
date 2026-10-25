<?php

declare(strict_types=1);

namespace App\Shared\Domain\Model\Exception;

use Throwable;

/**
 * Marks the exceptions that mean a request was understood and refused.
 */
interface DomainExceptionInterface extends Throwable
{
}
