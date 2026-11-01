package challenge;

public final class BCryptBench {
    public static void main(String[] args) {
        BCrypt bcrypt = new BCrypt();
        for (int lanes : new int[] {1, 2, 4}) {
            String[] passwords = new String[lanes];
            String[] salts = new String[lanes];
            for (int i = 0; i < lanes; i++) {
                passwords[i] = "password" + i;
                salts[i] = "$2b$10$ZSfEoPvlcsj2XfvsSeK25e";
            }
            for (int i = 0; i < 12; i++) {
                bcrypt.calculateBatch(passwords, salts);
            }
            int batches = 24;
            long start = System.nanoTime();
            for (int i = 0; i < batches; i++) {
                bcrypt.calculateBatch(passwords, salts);
            }
            System.out.printf("%d lane(s): %.2f ms per hash%n", lanes, (System.nanoTime() - start) / 1e6 / (batches * lanes));
        }
    }
}
