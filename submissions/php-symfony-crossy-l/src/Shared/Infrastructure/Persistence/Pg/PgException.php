<?php

declare(strict_types=1);

namespace App\Shared\Infrastructure\Persistence\Pg;

use RuntimeException;

/**
 * A Postgres call failed. The subclasses say whether the connection survived.
 */
abstract class PgException extends RuntimeException
{
}
