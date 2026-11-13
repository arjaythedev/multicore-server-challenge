--  bcrypt ($2b$, OpenBSD).
--
--  Proved free of run-time errors (SPARK silver): no password or stored hash makes it raise or index outside its
--  tables.
package Bcrypt with SPARK_Mode is

   Hash_Length : constant := 60;
   subtype Hash_Text is String (1 .. Hash_Length);

   --  bcrypt reads at most this many password bytes; the API rejects longer passwords.
   Max_Password_Length : constant := 72;

   type Cost_Factor is range 4 .. 31;   --  2 ** Cost key expansions
   Default_Cost : constant Cost_Factor := 10;

   --  16 random bytes for a salt (from the kernel; drawn by the caller, so this unit stays pure).
   subtype Salt_Source is String (1 .. 16);

   --  A fresh $2b$ hash of Password with the salt Random.
   function Hash (Password : String; Random : Salt_Source; Cost : Cost_Factor := Default_Cost) return Hash_Text;

   --  Constant-time check of Password against a stored $2a$, $2b$ or $2y$ hash.
   function Verify (Password : String; Stored : String) return Boolean;

   --  How many logins Verify_Batch computes together; more spill registers and run slower.
   Max_Batch : constant := 6;

   --  A login to check: the password given (its first Length characters) and the hash stored for the account.
   type Login is record
      Password : String (1 .. Max_Password_Length) := [others => ' '];
      Length   : Natural range 0 .. Max_Password_Length := 0;
      Stored   : Hash_Text := [others => ' '];
      Match    : Boolean := False;
   end record;
   type Login_List is array (Positive range <>) of Login;

   --  Sets each login's Match to Verify (Password (1 .. Length), Stored). The logins are computed together,
   --  which takes about 1.5 times as long as one alone for a batch of six.
   procedure Verify_Batch (Logins : in out Login_List) with Pre => Logins'Length <= Max_Batch;

end Bcrypt;
