using System.Diagnostics;
using System.Text;
using Conduit;

// Differential test: every hash Bcrypt.cs makes must verify under BCrypt.Net-Next and vice versa, for random passwords (ASCII, Latin, CJK,
// 1-72 bytes), every lane count and cost 4 (fast); then the cost-10 reference check and the timing of 1-4 jobs per Run.
var rnd = new Random(7);
int failures = 0;

string RandomPassword()
{
    int bytes = rnd.Next(1, 73);
    var sb = new StringBuilder();
    while (Encoding.UTF8.GetByteCount(sb.ToString()) < bytes)
    {
        int kind = rnd.Next(10);
        sb.Append(kind < 7 ? (char)rnd.Next(33, 127) : kind < 9 ? (char)rnd.Next(0xa1, 0x24f) : (char)rnd.Next(0x4e00, 0x4e80));
    }
    var s = sb.ToString();
    while (Encoding.UTF8.GetByteCount(s) > 72) s = s[..^1];
    return s;
}

void Check(bool ok, string what)
{
    if (ok) return;
    failures++;
    Console.WriteLine("FAIL " + what);
}

for (int round = 0; round < 400; round++)
{
    int lanes = 1 + round % 4;
    var passwords = Enumerable.Range(0, lanes).Select(_ => RandomPassword()).ToArray();

    var mine = passwords.Select(p => Bcrypt.Job.ForHash(p, 4)!).ToArray();
    Bcrypt.Run(mine);
    for (int i = 0; i < lanes; i++) Check(BCrypt.Net.BCrypt.Verify(passwords[i], mine[i].Encoded()), $"BCrypt.Net rejects our hash ({lanes} lanes)");

    var theirs = passwords.Select(p => BCrypt.Net.BCrypt.HashPassword(p, 4)).ToArray();
    var checks = Enumerable.Range(0, lanes).Select(i => Bcrypt.Job.ForVerify(passwords[i], theirs[i])!).ToArray();
    Bcrypt.Run(checks);
    for (int i = 0; i < lanes; i++) Check(checks[i].Matches(theirs[i]), $"we reject a BCrypt.Net hash ({lanes} lanes)");

    var wrong = Bcrypt.Job.ForVerify(passwords[0] + "x", theirs[0]);
    if (wrong is not null)
    {
        Bcrypt.Run([wrong]);
        Check(!wrong.Matches(theirs[0]), "a wrong password matched");
    }
}

var reference = BCrypt.Net.BCrypt.HashPassword("password123", 10);
var job = Bcrypt.Job.ForVerify("password123", reference)!;
Bcrypt.Run([job]);
Check(job.Matches(reference), "cost-10 hash");
Check(Bcrypt.Job.ForVerify("x", "$2b$10$" + reference[7..]) is not null && Bcrypt.Job.ForVerify("x", "$2y$10$" + reference[7..]) is not null, "$2b$ and $2y$ prefixes");
Check(Bcrypt.Job.ForVerify("x", "garbage") is null && Bcrypt.Job.ForVerify("x", reference[..59]) is null, "malformed hashes");
Check(Bcrypt.Job.ForVerify(new string('a', 73), reference) is null && Bcrypt.Job.ForHash(new string('a', 73), 10) is null, "73-byte passwords");
Console.WriteLine(failures == 0 ? "bcrypt matches BCrypt.Net-Next" : $"{failures} failures");

static double MsPerHash(Action work, int hashes)
{
    work();
    var sw = Stopwatch.StartNew();
    work();
    return sw.Elapsed.TotalMilliseconds / hashes;
}

Console.WriteLine($"BCrypt.Net-Next          {MsPerHash(() => { for (int i = 0; i < 6; i++) BCrypt.Net.BCrypt.Verify("password123", reference); }, 6),6:F1} ms per hash");
for (int lanes = 1; lanes <= Bcrypt.MaxLanes; lanes++)
{
    var jobs = Enumerable.Range(0, lanes).Select(_ => Bcrypt.Job.ForVerify("password123", reference)!).ToArray();
    Console.WriteLine($"Bcrypt.Run, {lanes} job(s)       {MsPerHash(() => { for (int i = 0; i < 6; i++) Bcrypt.Run(jobs); }, 6 * lanes),6:F1} ms per hash");
}
return failures == 0 ? 0 : 1;
