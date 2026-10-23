# vibe.d DB example
In the vibe_example folder you can find example of the project, where is shown how to work with postgres queries properly.

# performance suggestions
don't use nginx. lets use server directly
prepare sql once. init it and reuse later
use one reused DB connection
use group commit - many writes - one commit
for jwt - use jwtlited (the fastest in D)
