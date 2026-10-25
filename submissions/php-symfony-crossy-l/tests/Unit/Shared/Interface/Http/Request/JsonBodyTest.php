<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Interface\Http\Request;

use App\Shared\Domain\Model\Exception\ValidationException;
use App\Shared\Interface\Http\Request\JsonBody;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use stdClass;

final class JsonBodyTest extends TestCase
{
    /** @return iterable<string, array{string}> */
    public static function invalidBodies(): iterable
    {
        foreach (['', '{', 'null', '[]', '{}', '{"user":[]}', '{"user":null}', '{"user":"x"}', '{"User":{}}'] as $body) {
            yield 'body ' . $body => [$body];
        }
    }

    #[DataProvider('invalidBodies')]
    public function testRequiresAnObjectInsideTheNamedWrapper(string $content): void
    {
        $this->expectException(ValidationException::class);
        JsonBody::unwrap($content, 'user');
    }

    /** @return iterable<string, array{mixed}> */
    public static function invalidRequiredStrings(): iterable
    {
        foreach ([null, '', 1, true, [], new stdClass()] as $value) {
            yield get_debug_type($value) . json_encode($value) => [$value];
        }
    }

    #[DataProvider('invalidRequiredStrings')]
    public function testRequiredStringsRejectMissingEmptyAndNonStringValues(mixed $value): void
    {
        $body = JsonBody::unwrap(json_encode(['user' => ['name' => $value]], JSON_THROW_ON_ERROR), 'user');

        $this->expectException(ValidationException::class);
        $body->requiredString('name');
    }

    public function testNullAndAbsentFieldsAreUnchangedWhileEmptyTextAndWhitespaceArePreserved(): void
    {
        $body = JsonBody::unwrap('{"user":{"null":null,"empty":"","spaces":"  "}}', 'user');

        self::assertNull($body->optionalString('missing'));
        self::assertNull($body->optionalString('null'));
        self::assertSame('', $body->optionalString('empty'));
        self::assertSame('  ', $body->requiredString('spaces'));
        self::assertSame([], $body->optionalStringList('missing'));
    }

    /** @return iterable<string, array{mixed}> */
    public static function invalidLists(): iterable
    {
        foreach (['x', false, [''], ['x', 1], ['x', null], new stdClass()] as $value) {
            yield json_encode($value) => [$value];
        }
    }

    #[DataProvider('invalidLists')]
    public function testTagListsRequireNonEmptyStrings(mixed $value): void
    {
        $body = JsonBody::unwrap(json_encode(['article' => ['tagList' => $value]], JSON_THROW_ON_ERROR), 'article');

        $this->expectException(ValidationException::class);
        $body->optionalStringList('tagList');
    }
}
