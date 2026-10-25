<?php

declare(strict_types=1);

namespace App\Tests\PHPStan;

use PhpParser\Node;
use PhpParser\Node\Param;
use PhpParser\Node\Stmt\Class_;
use PhpParser\Node\Stmt\Property;
use PHPStan\Analyser\Scope;
use PHPStan\Rules\IdentifierRuleError;
use PHPStan\Rules\Rule;
use PHPStan\Rules\RuleErrorBuilder;

/**
 * A handler reads nothing: it authorizes the caller and delegates by id, so it holds no repository, and a command
 * handler holds no read service either.
 *
 * @implements Rule<Class_>
 */
final class HandlerNoReadRule implements Rule
{
    private const array REPOSITORY_SUFFIXES = ['Repository', 'RepositoryInterface'];

    private const array READ_SERVICE_SUFFIXES = ['ReadService', 'ReadServiceInterface'];

    public function getNodeType(): string
    {
        return Class_::class;
    }

    /**
     * @return list<IdentifierRuleError>
     */
    public function processNode(Node $node, Scope $scope): array
    {
        $className = $node->name?->toString();

        if ($className === null) {
            return [];
        }

        $isCommandHandler = str_ends_with($className, 'CommandHandler');

        if (!$isCommandHandler && !str_ends_with($className, 'QueryHandler')) {
            return [];
        }

        $forbidden = $isCommandHandler
            ? [...self::REPOSITORY_SUFFIXES, ...self::READ_SERVICE_SUFFIXES]
            : self::REPOSITORY_SUFFIXES;

        $errors = [];

        foreach ($this->dependencyTypes($node) as $type) {
            if (!$this->endsWithAny($type, $forbidden)) {
                continue;
            }

            $errors[] = RuleErrorBuilder::message(\sprintf(
                'Handler class %s depends on %s. A handler reads nothing: authorize the caller, then '
                . 'delegate by id to the layer that owns the write.',
                $className,
                $type,
            ))->identifier('app.handlerNoRead')->build();
        }

        return $errors;
    }

    /**
     * The types a handler is constructed with, promoted or declared.
     *
     * @return list<string>
     */
    private function dependencyTypes(Class_ $node): array
    {
        $types = [];

        foreach ($node->getMethod('__construct')->params ?? [] as $param) {
            $types[] = $this->paramTypeName($param);
        }

        foreach ($node->getProperties() as $property) {
            $types[] = $this->propertyTypeName($property);
        }

        return array_values(array_filter($types));
    }

    private function paramTypeName(Param $param): ?string
    {
        return $param->type instanceof Node\Name ? $param->type->toString() : null;
    }

    private function propertyTypeName(Property $property): ?string
    {
        return $property->type instanceof Node\Name ? $property->type->toString() : null;
    }

    /**
     * @param list<string> $suffixes
     */
    private function endsWithAny(string $type, array $suffixes): bool
    {
        foreach ($suffixes as $suffix) {
            if (str_ends_with($type, $suffix)) {
                return true;
            }
        }

        return false;
    }
}
