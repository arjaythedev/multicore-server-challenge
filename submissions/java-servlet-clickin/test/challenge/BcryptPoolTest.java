package challenge;

import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import challenge.pg.Unit;

public final class BcryptPoolTest {
    public static void main(String[] args) throws Exception {
        LinkedBlockingQueue<Unit> completions = new LinkedBlockingQueue<>();
        Thread owner = Thread.currentThread();
        Unit unit = new Unit(completions::add, u -> {
            if (Thread.currentThread() != owner || !u.bcryptMatches) {
                throw new AssertionError("callback or result");
            }
        },
                        false,
                        false);
        unit.bcryptPassword = "U*U";
        unit.bcryptHash = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";
        try (BcryptPool pool = new BcryptPool(2)) {
            pool.submit(unit);
            Unit result = completions.poll(10, TimeUnit.SECONDS);
            if (result != unit) {
                throw new AssertionError("missing completion");
            }
            result.callback.done(result);
            Unit[] jobs = new Unit[9];
            for (int i = 0; i < jobs.length; i++) {
                jobs[i] = new Unit(completions::add, u -> {}, false, false);
                jobs[i].bcryptPassword = i % 2 == 0 ? "U*U" : "wrong";
                jobs[i].bcryptHash = i == 8 ? "invalid" : "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";
                pool.submit(jobs[i]);
            }
            for (int i = 0; i < jobs.length; i++) {
                Unit completed = completions.poll(10, TimeUnit.SECONDS);
                if (completed == null
                        || completed.errorMessage != null
                        || (completed != jobs[8] && completed.bcryptMatches != "U*U".equals(completed.bcryptPassword))) {
                    throw new AssertionError("batch result");
                }
                if (completed == jobs[8] && completed.bcryptMatches) {
                    throw new AssertionError("invalid hash");
                }
            }
        }
        BcryptPool pool = new BcryptPool(1);
        Unit newHash = new Unit(completions::add, u -> {}, false, false);
        newHash.bcryptPassword = "new password";
        pool.submit(newHash);
        pool.close();
        if (completions.poll(10, TimeUnit.SECONDS) != newHash
                || newHash.errorMessage != null
                || !newHash.bcryptHash.startsWith("$2b$10$")
                || !new BCrypt().verify(newHash.bcryptPassword, newHash.bcryptHash)) {
            throw new AssertionError("hash after close");
        }
    }
}
