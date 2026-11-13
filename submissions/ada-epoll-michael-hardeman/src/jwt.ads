--  HS256 JSON Web Tokens: {"sub": "<id>", "iat": now, "exp": now + 30 days}. Verified on every request. The
--  key is JWT_SECRET (Settings), keyed once as the program elaborates.
--
--  Proved free of run-time errors (SPARK silver): no token, however malformed, makes Verify raise or read outside
--  it, and nothing in a token is read before its signature has been checked.
with Model; use Model;

package Jwt with SPARK_Mode is

   --  A token for User issued at Now.
   function Sign (User : Known_User; Now : Unix_Seconds) return String
      with Pre => Now in 0 .. 10 ** 15;

   type Verdict (Valid : Boolean := False) is record
      case Valid is
         when True  => User : Known_User;
         when False => null;
      end case;
   end record;

   Max_Token_Length : constant := 4096;

   --  Valid when the signature matches, alg is HS256, exp is after Now, nbf (if any) is not after Now and sub is
   --  a string holding a positive integer.
   function Verify (Token : String; Now : Unix_Seconds) return Verdict
      with Pre => Token'First >= 1 and then Token'Last < Positive'Last;

end Jwt;
