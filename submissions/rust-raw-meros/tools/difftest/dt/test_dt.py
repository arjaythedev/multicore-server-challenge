"""Self-tests of the comparison and JWT helpers: `python3 -m unittest dt.test_dt` in tools/difftest."""
import time
import unittest

from . import compare, jwtmint

SECRET = "s3cret"


class JwtTests(unittest.TestCase):
    def test_minted_token_verifies(self):
        claims, why = jwtmint.check(jwtmint.mint(42, SECRET), SECRET)
        self.assertEqual((claims["sub"], why), ("42", ""))

    def test_every_rejected_token_fails_the_check(self):
        for label, token in jwtmint.rejected_tokens(SECRET, 7, int(time.time())):
            self.assertIsNone(jwtmint.check(token, SECRET)[0], label)

    def test_wrong_secret_fails(self):
        self.assertIsNone(jwtmint.check(jwtmint.mint(1, "other"), SECRET)[0])


class CompareTests(unittest.TestCase):
    def test_first_diff_is_type_strict(self):
        self.assertIsNotNone(compare.first_diff({"n": 1}, {"n": True}))
        self.assertIsNotNone(compare.first_diff({"n": 1}, {"n": 1.0}))
        self.assertIsNone(compare.first_diff({"a": [1, {"b": None}]}, {"a": [1, {"b": None}]}))

    def test_first_diff_reports_path_and_length(self):
        self.assertEqual(compare.first_diff({"a": [1, 2]}, {"a": [1, 3]})[0], "$.a[1]")
        self.assertEqual(compare.first_diff({"a": [1]}, {"a": [1, 2]})[0], "$.a.length")

    def test_normaliser_rewrites_error_text_tokens_and_fresh_timestamps(self):
        start = time.time()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(start))
        norm = compare.Normaliser(SECRET, start, None, expect_token=False)
        out = norm.body({"user": {"token": jwtmint.mint(5, SECRET)}, "createdAt": stamp,
                         "updatedAt": "2024-01-01T00:00:00.000Z"})
        self.assertEqual(out, {"user": {"token": "<jwt sub=5>"}, "createdAt": "<fresh ts>",
                               "updatedAt": "2024-01-01T00:00:00.000Z"})
        self.assertEqual(norm.body({"errors": {"body": ["whatever"]}}), {"errors": {"body": ["<msg>"]}})

    def test_bad_token_and_bad_timestamp_are_flagged(self):
        norm = compare.Normaliser(SECRET, time.time(), None, expect_token=False)
        self.assertIn("INVALID JWT", norm.body({"token": "x.y.z"})["token"])
        self.assertIn("BAD TIMESTAMP", norm.body({"createdAt": "2024-01-01T00:00:00Z"})["createdAt"])


if __name__ == "__main__":
    unittest.main()
