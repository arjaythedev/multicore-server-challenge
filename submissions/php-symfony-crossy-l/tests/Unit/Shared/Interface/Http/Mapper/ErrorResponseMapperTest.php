<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http\Mapper;

use App\Shared\Interface\Http\Mapper\ErrorResponseMapper;
use PHPUnit\Framework\TestCase;

final class ErrorResponseMapperTest extends TestCase
{
    public function testTheMessagesAreTheBodyOfTheErrors(): void
    {
        self::assertSame(['body' => ['title can\'t be blank', 'body can\'t be blank']], (new ErrorResponseMapper())->toResponse(['title can\'t be blank', 'body can\'t be blank'])->errors);
    }
}
