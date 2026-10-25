<?php

declare(strict_types=1);

namespace App\Module\Profile\Interface\Http\Response;

use App\Shared\Interface\Http\Response\ProfileResponse;

/**
 * {"profile": Profile}
 */
final readonly class ProfileEnvelopeResponse
{
    public function __construct(
        public ProfileResponse $profile,
    ) {
    }
}
