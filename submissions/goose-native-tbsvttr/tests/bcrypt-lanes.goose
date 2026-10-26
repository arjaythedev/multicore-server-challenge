// Independent single-lane reference versus each newly interleaved lane count.
// Different keys and salts catch cross-lane state reuse; cost10 is the real workload.
import std;
import bcrypt;

fn main() {
    let passwords: const u8[:][5] = ["", "password", "één 🙂", "different password", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"];
    var keys: u32[18][5] = [[0; 18]; 5];
    var salts: u32[18][5] = [[0; 18]; 5];
    for i in 5 {
        key_words(passwords[i], keys[i]);
        var salt: u8[16] = [0; 16];
        for j in 16 { salt[j] = (i * 31 + j * 7) as! u8; }
        stream_words(salt, salts[i]);
    }
    var checks = 0;
    for cost in [4, 5, 10] {
        var expected: u32[6][5] = [[0; 6]; 5];
        for i in 5 { hash1(keys[i], salts[i], cost, expected[i]); }
        for lanes in [2, 3, 4, 5] {
            var actual: u32[6][5] = [[0; 6]; 5];
            if lanes == 2 { hash2(keys, salts, cost, actual); }
            else if lanes == 3 { hash3(keys, salts, cost, actual); }
            else if lanes == 4 { hash4(keys, salts, cost, actual); }
            else { hash5(keys, salts, cost, actual); }
            for i in lanes {
                for j in 6 { assert(actual[i][j] == expected[i][j]); checks += 1; }
            }
        }
    }
    print("PASS: ", checks, " exact-lane bcrypt comparisons, independent keys/salts, costs4/5/10");
}
