<?php

declare(strict_types=1);

namespace App\Tests\Unit\Shared\Application\Mapper;

use App\Shared\Application\Mapper\ProfileResultMapper;
use App\Shared\Domain\View\ProfileView;
use PHPUnit\Framework\TestCase;

final class ProfileResultMapperTest extends TestCase
{
    public function testEveryFieldOfTheViewComesAcross(): void
    {
        $result = (new ProfileResultMapper())->toResult(new ProfileView('jake', 'I work at statefarm', 'https://example.test/jake.png', true));

        self::assertSame('jake', $result->username);
        self::assertSame('I work at statefarm', $result->bio);
        self::assertSame('https://example.test/jake.png', $result->image);
        self::assertTrue($result->following);
    }

    public function testAMissingBioAndImageStayMissing(): void
    {
        $result = (new ProfileResultMapper())->toResult(new ProfileView('anna', null, null, false));

        self::assertNull($result->bio);
        self::assertNull($result->image);
        self::assertFalse($result->following);
    }
}
