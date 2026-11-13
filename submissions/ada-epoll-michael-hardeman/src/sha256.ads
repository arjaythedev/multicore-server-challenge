--  SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104) over byte strings.
with Interfaces; use Interfaces;

package Sha256 with SPARK_Mode is

   subtype Digest is String (1 .. 32);
   Block_Length : constant := 64;

   type Context is private;
   function Start return Context;
   procedure Update (This : in out Context; Data : String);
   function Finish (This : Context) return Digest;
   function Hash (Data : String) return Digest;

   --  An HMAC key with its inner and outer pad blocks already absorbed, so every MAC starts from them.
   type Hmac_Key is private;
   function To_Hmac_Key (Secret : String) return Hmac_Key;
   function Hmac (Key : Hmac_Key; Data : String) return Digest;
   function Hmac (Secret : String; Data : String) return Digest;

   --  Equality that takes the same time wherever the first difference is.
   function Constant_Time_Equal (Left, Right : String) return Boolean
      with Post => Constant_Time_Equal'Result = (Left = Right);

private

   type Word_Index is range 0 .. 7;
   type State is array (Word_Index) of Unsigned_32;
   subtype Block_Fill is Natural range 0 .. Block_Length - 1;   --  a full block is compressed at once

   type Context is record
      Hash_State   : State;
      Block        : String (1 .. Block_Length);
      Filled       : Block_Fill := 0;
      Total_Length : Unsigned_64 := 0;   --  bytes
   end record;

   type Hmac_Key is record
      Inner, Outer : Context;
   end record;

end Sha256;
