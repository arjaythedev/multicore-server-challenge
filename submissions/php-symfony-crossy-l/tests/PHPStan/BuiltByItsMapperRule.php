<?php

declare(strict_types=1);

namespace App\Tests\PHPStan;

use PhpParser\Node;
use PhpParser\Node\Expr;
use PhpParser\Node\Expr\New_;
use PhpParser\Node\Expr\StaticCall;
use PhpParser\Node\Name;
use PHPStan\Analyser\Scope;
use PHPStan\Rules\IdentifierRuleError;
use PHPStan\Rules\Rule;
use PHPStan\Rules\RuleErrorBuilder;

/**
 * Builds every result, response, view and domain model that is translated from something else in the mapper named
 * after it, and nowhere else: ProfileResultMapper builds ProfileResult, ArticleViewMapper builds ArticleView and, with
 * toViewList(), an ArticleViewList. Results and responses are checked wherever they are built; views and domain
 * models where infrastructure builds them from rows. Exceptions, and the moment PgValue parses from one column, are
 * not checked.
 *
 * @implements Rule<Expr>
 */
final class BuiltByItsMapperRule implements Rule
{
    /** The namespaces of results and responses, which are checked wherever they are built. */
    private const array EVERYWHERE = ['\\Application\\Result\\', '\\Interface\\Http\\Response\\'];

    /** The namespaces of views and domain models, which are checked where infrastructure builds them. */
    private const array FROM_INFRASTRUCTURE = ['\\Domain\\View\\', '\\Domain\\Model\\'];

    /** Built where they are needed: a value read from one column, not an object read from a row. */
    private const array VALUES = ['App\\Shared\\Domain\\Model\\Moment'];

    public function getNodeType(): string
    {
        return Expr::class;
    }

    /**
     * @return list<IdentifierRuleError>
     */
    public function processNode(Node $node, Scope $scope): array
    {
        if (!$node instanceof New_ && !$node instanceof StaticCall) {
            return [];
        }

        if (!$node->class instanceof Name) {
            return [];
        }

        $built = $scope->resolveName($node->class);
        $in = $scope->getClassReflection()?->getName();

        if (!self::isChecked($built, $in)) {
            return [];
        }

        if ($in !== null && self::isItsMapper(self::shortName($in), self::shortName($built))) {
            return [];
        }

        return [RuleErrorBuilder::message(\sprintf(
            '%s is built here, outside its own mapper. Build it in %s and call `$this->mapper->toResult()`, '
            . '`->toResponse()`, `->toView()` or `->toDomain()` where it is needed, even for a wrapper of one field.',
            self::shortName($built),
            self::mapperName($built),
        ))->identifier('app.builtOutsideItsMapper')->build()];
    }

    private static function isChecked(string $built, ?string $in): bool
    {
        if (self::inAny($built, self::EVERYWHERE)) {
            return true;
        }

        return $in !== null
            && str_contains($in, '\\Infrastructure\\')
            && self::inAny($built, self::FROM_INFRASTRUCTURE)
            && !str_contains($built, '\\Exception\\')
            && !\in_array($built, self::VALUES, true);
    }

    /**
     * @param list<string> $namespaces
     */
    private static function inAny(string $class, array $namespaces): bool
    {
        foreach ($namespaces as $namespace) {
            if (str_contains($class, $namespace)) {
                return true;
            }
        }

        return false;
    }

    /**
     * A type is built by the mapper named after it, and a list also by the mapper of its item.
     */
    private static function isItsMapper(string $mapper, string $built): bool
    {
        return $mapper === $built . 'Mapper'
            || (str_ends_with($built, 'List') && $mapper === substr($built, 0, -4) . 'Mapper');
    }

    private static function mapperName(string $built): string
    {
        return $built . 'Mapper';
    }

    private static function shortName(string $class): string
    {
        $position = strrpos($class, '\\');

        return $position === false ? $class : substr($class, $position + 1);
    }
}
