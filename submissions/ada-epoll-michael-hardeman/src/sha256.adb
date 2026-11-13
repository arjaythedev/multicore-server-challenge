package body Sha256 with SPARK_Mode is

   type Round is range 0 .. 63;

   Round_Constants : constant array (Round) of Unsigned_32 :=
     [16#428a2f98#, 16#71374491#, 16#b5c0fbcf#, 16#e9b5dba5#, 16#3956c25b#, 16#59f111f1#, 16#923f82a4#, 16#ab1c5ed5#,
      16#d807aa98#, 16#12835b01#, 16#243185be#, 16#550c7dc3#, 16#72be5d74#, 16#80deb1fe#, 16#9bdc06a7#, 16#c19bf174#,
      16#e49b69c1#, 16#efbe4786#, 16#0fc19dc6#, 16#240ca1cc#, 16#2de92c6f#, 16#4a7484aa#, 16#5cb0a9dc#, 16#76f988da#,
      16#983e5152#, 16#a831c66d#, 16#b00327c8#, 16#bf597fc7#, 16#c6e00bf3#, 16#d5a79147#, 16#06ca6351#, 16#14292967#,
      16#27b70a85#, 16#2e1b2138#, 16#4d2c6dfc#, 16#53380d13#, 16#650a7354#, 16#766a0abb#, 16#81c2c92e#, 16#92722c85#,
      16#a2bfe8a1#, 16#a81a664b#, 16#c24b8b70#, 16#c76c51a3#, 16#d192e819#, 16#d6990624#, 16#f40e3585#, 16#106aa070#,
      16#19a4c116#, 16#1e376c08#, 16#2748774c#, 16#34b0bcb5#, 16#391c0cb3#, 16#4ed8aa4a#, 16#5b9cca4f#, 16#682e6ff3#,
      16#748f82ee#, 16#78a5636f#, 16#84c87814#, 16#8cc70208#, 16#90befffa#, 16#a4506ceb#, 16#bef9a3f7#, 16#c67178f2#];

   Initial_State : constant State :=
     [16#6a09e667#, 16#bb67ae85#, 16#3c6ef372#, 16#a54ff53a#, 16#510e527f#, 16#9b05688c#, 16#1f83d9ab#, 16#5be0cd19#];

   ----------
   -- Byte --
   ----------

   function Byte (Data : String; Position : Positive) return Unsigned_32 is
     (Unsigned_32 (Character'Pos (Data (Position))))
      with Inline, Pre => Position in Data'Range;

   --------------
   -- Compress --
   --------------

   --  One 64-byte block into the state. A .. H, T1, T2 and the sigma functions are FIPS 180-4's names.
   procedure Compress (Hash_State : in out State; Block : String)
      with Inline, Pre => Block'Length = Block_Length
   is
      Schedule : array (Round) of Unsigned_32 := [others => 0];   --  for flow analysis: the loops fill it
      A : Unsigned_32 := Hash_State (0);
      B : Unsigned_32 := Hash_State (1);
      C : Unsigned_32 := Hash_State (2);
      D : Unsigned_32 := Hash_State (3);
      E : Unsigned_32 := Hash_State (4);
      F : Unsigned_32 := Hash_State (5);
      G : Unsigned_32 := Hash_State (6);
      H : Unsigned_32 := Hash_State (7);
      T1, T2 : Unsigned_32;
   begin
      for I in Round range 0 .. 15 loop
         declare
            P : constant Positive := Block'First + 4 * Natural (I);
         begin
            Schedule (I) := Shift_Left (Byte (Block, P), 24) or Shift_Left (Byte (Block, P + 1), 16)
              or Shift_Left (Byte (Block, P + 2), 8) or Byte (Block, P + 3);
         end;
      end loop;

      for I in Round range 16 .. 63 loop
         declare
            W15    : constant Unsigned_32 := Schedule (I - 15);
            W2     : constant Unsigned_32 := Schedule (I - 2);
            Sigma0 : constant Unsigned_32 := Rotate_Right (W15, 7) xor Rotate_Right (W15, 18) xor Shift_Right (W15, 3);
            Sigma1 : constant Unsigned_32 := Rotate_Right (W2, 17) xor Rotate_Right (W2, 19) xor Shift_Right (W2, 10);
         begin
            Schedule (I) := Schedule (I - 16) + Sigma0 + Schedule (I - 7) + Sigma1;
         end;
      end loop;

      for I in Round loop
         T1 := H + (Rotate_Right (E, 6) xor Rotate_Right (E, 11) xor Rotate_Right (E, 25))
           + ((E and F) xor ((not E) and G)) + Round_Constants (I) + Schedule (I);
         T2 := (Rotate_Right (A, 2) xor Rotate_Right (A, 13) xor Rotate_Right (A, 22))
           + ((A and B) xor (A and C) xor (B and C));
         H := G;
         G := F;
         F := E;
         E := D + T1;
         D := C;
         C := B;
         B := A;
         A := T1 + T2;
      end loop;

      Hash_State := [Hash_State (0) + A, Hash_State (1) + B, Hash_State (2) + C, Hash_State (3) + D,
                     Hash_State (4) + E, Hash_State (5) + F, Hash_State (6) + G, Hash_State (7) + H];
   end Compress;

   -----------
   -- Start --
   -----------

   function Start return Context is
     (Hash_State => Initial_State, Block => [others => ASCII.NUL], Filled => 0, Total_Length => 0);

   ------------
   -- Update --
   ------------

   procedure Update (This : in out Context; Data : String) is
      Used : Natural := 0;   --  bytes of Data taken so far
   begin
      This.Total_Length := This.Total_Length + Unsigned_64 (Data'Length);

      while Used < Data'Length loop
         pragma Loop_Invariant (Used < Data'Length);
         pragma Loop_Variant (Increases => Used);
         if This.Filled = 0 and then Data'Length - Used >= Block_Length then
            declare
               Next : constant Positive := Data'First + Used;
            begin
               Compress (This.Hash_State, Data (Next .. Next + (Block_Length - 1)));   --  whole blocks straight through
            end;
            Used := Used + Block_Length;
         else
            declare
               Count  : constant Positive := Natural'Min (Block_Length - This.Filled, Data'Length - Used);
               Next   : constant Positive := Data'First + Used;
               Filled : constant Positive := This.Filled + Count;
            begin
               This.Block (This.Filled + 1 .. Filled) := Data (Next .. Next + (Count - 1));
               Used                                   := Used + Count;

               if Filled = Block_Length then
                  Compress (This.Hash_State, This.Block);
                  This.Filled := 0;
               else
                  This.Filled := Filled;
               end if;
            end;
         end if;
      end loop;
   end Update;

   ------------
   -- Finish --
   ------------

   function Finish (This : Context) return Digest is
      Final      : Context := This;
      Bit_Length : constant Unsigned_64 := This.Total_Length * 8;
      Result     : Digest := [others => ASCII.NUL];
      Marker     : constant Positive := This.Filled + 1;   --  the 16#80# after the message
      Zero_From  : Positive := Marker + 1;                 --  zeros from here up to the length field
   begin
      Final.Block (Marker) := Character'Val (16#80#);
      if Marker > Block_Length - 8 then
         Final.Block (Marker + 1 .. Block_Length) := [others => ASCII.NUL];
         Compress (Final.Hash_State, Final.Block);
         Zero_From := 1;
      end if;

      Final.Block (Zero_From .. Block_Length - 8) := [others => ASCII.NUL];
      for I in 0 .. 7 loop
         Final.Block (Block_Length - 7 + I) := Character'Val (Shift_Right (Bit_Length, 56 - 8 * I) and 255);
      end loop;
      Compress (Final.Hash_State, Final.Block);

      for I in Word_Index loop
         for J in 0 .. 3 loop
            Result (4 * Natural (I) + J + 1) := Character'Val (Shift_Right (Final.Hash_State (I), 24 - 8 * J) and 255);
         end loop;
      end loop;

      return Result;
      end Finish;

   ----------
   -- Hash --
   ----------

   function Hash (Data : String) return Digest is
      This : Context := Start;
   begin
      Update (This, Data);
      return Finish (This);
   end Hash;

   -----------------
   -- To_Hmac_Key --
   -----------------

   function To_Hmac_Key (Secret : String) return Hmac_Key is
      Key_Block : String (1 .. Block_Length) := [others => ASCII.NUL];

      ------------
      -- Padded --
      ------------

      function Padded (Pad : Unsigned_8) return String is
         Result : String (1 .. Block_Length);
      begin
         for I in Result'Range loop
            Result (I) := Character'Val (Unsigned_8 (Character'Pos (Key_Block (I))) xor Pad);
         end loop;
         return Result;
      end Padded;

      Key : Hmac_Key := (Inner => Start, Outer => Start);
   begin
      if Secret'Length > Block_Length then
         Key_Block (Digest'Range) := Hash (Secret);
      else
         Key_Block (1 .. Secret'Length) := Secret;
      end if;

      Update (Key.Inner, Padded (16#36#));
      Update (Key.Outer, Padded (16#5c#));
      return Key;
   end To_Hmac_Key;

   ----------
   -- Hmac --
   ----------

   function Hmac (Key : Hmac_Key; Data : String) return Digest is
      Inner : Context := Key.Inner;
      Outer : Context := Key.Outer;
   begin
      Update (Inner, Data);
      Update (Outer, Finish (Inner));
      return Finish (Outer);
   end Hmac;

   ----------
   -- Hmac --
   ----------

   function Hmac (Secret : String; Data : String) return Digest is (Hmac (To_Hmac_Key (Secret), Data));

   -------------------------
   -- Constant_Time_Equal --
   -------------------------

   function Constant_Time_Equal (Left, Right : String) return Boolean is
      Difference : Unsigned_8 := 0;
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;

      for I in 0 .. Left'Length - 1 loop
         pragma Loop_Invariant
           ((Difference = 0) = (for all J in 0 .. I - 1 => Left (Left'First + J) = Right (Right'First + J)));
         Difference := Difference
           or (Unsigned_8 (Character'Pos (Left (Left'First + I)))
               xor Unsigned_8 (Character'Pos (Right (Right'First + I))));
      end loop;

      return Difference = 0;
   end Constant_Time_Equal;

end Sha256;
