<?php

declare(strict_types=1);

namespace App;

use LogicException;
use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
use Symfony\Component\HttpKernel\Kernel as BaseKernel;

class Kernel extends BaseKernel
{
    use MicroKernelTrait;

    /**
     * The kernel for the given APP_ENV and APP_DEBUG.
     *
     * @param array<mixed> $context
     */
    public static function fromContext(array $context): self
    {
        $environment = $context['APP_ENV'] ?? null;

        if (!\is_string($environment)) {
            throw new LogicException('APP_ENV is not set.');
        }

        return new self($environment, filter_var($context['APP_DEBUG'] ?? false, FILTER_VALIDATE_BOOL));
    }
}
