import bcrypt
import jwt

from conduit_server.ports.outbound import CryptoPort

_HS256 = "HS256"
_EXP_30_DAYS_SECONDS = 30 * 24 * 3600


class JoseBcryptCryptoAdapter(CryptoPort):
    def __init__(self, secret_key: str):
        self._secret = secret_key

    def hash_password(self, password: str) -> str:
        return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=10)).decode(
            "utf-8"
        )

    def verify_password(self, password: str, password_hash: str) -> bool:
        try:
            return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))
        except ValueError:
            return False

    def issue_token(self, user_id: int) -> str:
        import time

        now = int(time.time())
        payload = {"sub": str(user_id), "iat": now, "exp": now + _EXP_30_DAYS_SECONDS}
        return jwt.encode(payload, self._secret, algorithm=_HS256)

    def verify_token(self, token: str) -> int:
        """Verify HS256 signature + exp on every call (no caching). Returns user id."""
        header = jwt.get_unverified_header(token)
        if header.get("alg") != _HS256:
            raise jwt.InvalidAlgorithmError("only HS256 is accepted")
        payload = jwt.decode(
            token,
            self._secret,
            algorithms=[_HS256],
            options={"require": ["exp", "iat", "sub"]},
        )
        return int(payload["sub"])
