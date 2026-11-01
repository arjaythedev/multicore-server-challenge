package challenge;

import java.util.Arrays;

public final class BCryptTest {
    public static void main(String[] args) {
        BCrypt bcrypt = new BCrypt();
        String known = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";
        if (!bcrypt.calculate("U*U", known.substring(0, 29)).equals(known)) {
            throw new AssertionError("known vector");
        }
        if (!bcrypt.verify("U*U", known) || bcrypt.verify("wrong", known)) {
            throw new AssertionError("verify");
        }
        String known10 = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
        if (!bcrypt.verify("password123", known10)) {
            throw new AssertionError("cost 10 vector");
        }
        String[] passwords = {"", "한글🔒", "x".repeat(71), "x".repeat(72),
                "x".repeat(73)};
        String[] vectors = {"$2a$04$CCCCCCCCCCCCCCCCCCCCC.Cg0ly9t/KVBCBYYDfOmZKwry9JuXClC", "$2b$05$ZSfEoPvlcsj2XfvsSeK25e27C1uF0vytKDlDzSKG6tFwIhAz3sKEa",
                "$2y$04$......................MUTKUDIj4cZc60IEsGqjRod/wxELAN.", "$2a$04$CCCCCCCCCCCCCCCCCCCCC.ug0A3dTXhy5U.dFjx/qguZ8I4CB77BC", "$2a$04$CCCCCCCCCCCCCCCCCCCCC.ug0A3dTXhy5U.dFjx/qguZ8I4CB77BC"};
        for (int i = 0; i < passwords.length; i++) {
            if (!bcrypt.calculate(passwords[i], vectors[i].substring(0, 29)).equals(vectors[i])) {
                throw new AssertionError("vector " + i);
            }
        }
        for (int count = 1; count <= 4; count++) {
            String[] mixedPasswords = {"", "한글🔒", "x".repeat(73), "other"};
            String[] mixedSalts = {"$2a$05$CCCCCCCCCCCCCCCCCCCCC.", "$2b$05$ZSfEoPvlcsj2XfvsSeK25e", "$2y$05$......................", "$2a$05$ZSfEoPvlcsj2XfvsSeK25e"};
            String[] batch = bcrypt.calculateBatch(Arrays.copyOf(mixedPasswords, count), Arrays.copyOf(mixedSalts, count));
            for (int i = 0; i < count; i++) {
                if (!batch[i].equals(bcrypt.calculate(mixedPasswords[i], mixedSalts[i]))) {
                    throw new AssertionError("batch " + count + " lane " + i);
                }
            }
        }
        String[] mixedCost = {"$2a$04$CCCCCCCCCCCCCCCCCCCCC.", "$2b$05$ZSfEoPvlcsj2XfvsSeK25e", "$2y$04$......................", "$2a$05$ZSfEoPvlcsj2XfvsSeK25e"};
        String[] batch = bcrypt.calculateBatch(new String[] {"a", "b", "c", "d"}, mixedCost);
        for (int i = 0; i < 4; i++) {
            if (!batch[i].equals(bcrypt.calculate("" + (char) ('a' + i), mixedCost[i]))) {
                throw new AssertionError("mixed costs " + i);
            }
        }
        String hash = bcrypt.hash("password123");
        if (!hash.startsWith("$2b$10$") || !bcrypt.verify("password123", hash)) {
            throw new AssertionError("round trip");
        }
        if (!bcrypt.verify("U*U", "$2y$" + known.substring(4))) {
            throw new AssertionError("2y");
        }
    }
}
