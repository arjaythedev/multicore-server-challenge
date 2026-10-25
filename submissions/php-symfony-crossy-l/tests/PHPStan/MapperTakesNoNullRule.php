<?php

declare(strict_types=1);

namespace App\Tests\PHPStan;

use PhpParser\Node;
use PhpParser\Node\NullableType;
use PhpParser\Node\Stmt\ClassMethod;
use PhpParser\Node\UnionType;
use PHPStan\Analyser\Scope;
use PHPStan\Rules\IdentifierRuleError;
use PHPStan\Rules\Rule;
use PHPStan\Rules\RuleErrorBuilder;

/**
 * Keeps "is there one?" out of the mappers: one that takes a nullable and hands a nullable back passes the question on
 * to every caller. The call site writes `$x === null ? null : $mapper->toThing($x)` instead. A nullable in or out
 * alone is fine.
 *
 * @implements Rule<ClassMethod>
 */
final class MapperTakesNoNullRule implements Rule
{
    public function getNodeType(): string
    {
        return ClassMethod::class;
    }

    /**
     * @return list<IdentifierRuleError>
     */
    public function processNode(Node $node, Scope $scope): array
    {
        if (!$node->isPublic()) {
            return [];
        }

        $class = $scope->getClassReflection();

        if ($class === null || !str_ends_with($class->getName(), 'Mapper')) {
            return [];
        }

        if (!self::isNullable($node->returnType)) {
            return [];
        }

        $errors = [];

        foreach ($node->params as $param) {
            if (!self::isNullable($param->type)) {
                continue;
            }

            $method = $node->name->toString();

            $errors[] = RuleErrorBuilder::message(\sprintf(
                '%s::%s() takes $%s as nullable and hands the same maybe back. A mapper translates what '
                . 'it is given; whether there is anything to translate is the caller\'s question, and '
                . 'answering it here makes the answer a maybe for every caller that already knew. Write '
                . '`$x === null ? null : $mapper->%s($x)` at the call site.',
                $class->getName(),
                $method,
                self::nameOf($param),
                $method,
            ))->identifier('app.mapperNullableParameter')->line($param->getStartLine())->build();
        }

        return $errors;
    }

    private static function isNullable(?Node $type): bool
    {
        if ($type instanceof NullableType) {
            return true;
        }

        if (!$type instanceof UnionType) {
            return false;
        }

        foreach ($type->types as $member) {
            if ($member instanceof Node\Identifier && $member->toLowerString() === 'null') {
                return true;
            }
        }

        return false;
    }

    private static function nameOf(Node\Param $param): string
    {
        return $param->var instanceof Node\Expr\Variable && \is_string($param->var->name)
            ? $param->var->name
            : 'it';
    }
}
