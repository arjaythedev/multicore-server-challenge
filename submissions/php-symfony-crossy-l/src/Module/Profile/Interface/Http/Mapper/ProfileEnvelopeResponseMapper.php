<?php

declare(strict_types=1);

namespace App\Module\Profile\Interface\Http\Mapper;

use App\Module\Profile\Interface\Http\Response\ProfileEnvelopeResponse;
use App\Shared\Application\Result\ProfileResult;
use App\Shared\Interface\Http\Mapper\ProfileResponseMapper;

final class ProfileEnvelopeResponseMapper
{
    public function __construct(
        private readonly ProfileResponseMapper $profileResponseMapper,
    ) {
    }

    public function toResponse(ProfileResult $profile): ProfileEnvelopeResponse
    {
        return new ProfileEnvelopeResponse(profile: $this->profileResponseMapper->toResponse($profile));
    }
}
