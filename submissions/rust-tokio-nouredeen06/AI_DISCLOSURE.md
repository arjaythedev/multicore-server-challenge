# 100% AI-coded experiment

This contribution is **100% AI-coded**. Its **sole purpose is to see how far AI
can go at the Multicore Server Challenge** when given a performance objective,
the challenge rules, tools and feedback from a human.

The human supplied the objective, prompts and operating constraints, including
limits on testing the laptop, and requested submission. AI performed the
submission-specific implementation, optimization, benchmark tooling, documentation,
rule audit and pull-request preparation. No human-written code changes were
provided for this contribution.

## Existing work and attribution

The AI selected `rust-tokio-Scooter1337` as the starting implementation. That
submission in turn credits `rust-hyper-cknutson12`. The vendored PostgreSQL driver,
native bcrypt source and other dependencies also have their own authors.
Their code and licenses are retained and credited in [UPSTREAM.md](UPSTREAM.md),
[LICENSE](LICENSE), [native/README.md](native/README.md), and the vendored driver's
license/modification files.

The 100% AI-coded disclosure applies to the work performed for this contribution.
It does not reassign authorship of inherited code or dependencies to the AI or
the submitter. Reusing that existing work was part of the AI's approach and is
explicitly part of what this experiment measures.

## Evidence and limits

This is an experiment with recorded results, failures and limitations. The
submission has no official challenge score. Previous bounded validation passed
all 197 unchanged API checks, unit tests, a transaction integration check and
Clippy. Local load tests used a shared laptop and accelerated pacing; their
numbers cannot be converted into official user scores.

The human requested that local testing stop before this PR was prepared. No
additional local tests were run for the submission audit. The audit uses source
inspection and the retained validation evidence; the organizer's CI and official
benchmark remain the independent acceptance/scoring steps.
