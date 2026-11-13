with Interfaces; use Interfaces;
with Blowfish_Tables; use Blowfish_Tables;
with Sha256;

package body Bcrypt with SPARK_Mode is

   --  bcrypt's own base64 alphabet, without padding.
   Alphabet : constant String (1 .. 64) := "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

   No_Sextet : constant := -1;
   type Sextet_Table is array (Character) of Integer range No_Sextet .. 63;

   -------------
   -- Sextets --
   -------------

   function Sextets return Sextet_Table is
      Result : Sextet_Table := [others => No_Sextet];
   begin
      for Position in Alphabet'Range loop
         Result (Alphabet (Position)) := Position - Alphabet'First;
      end loop;
      return Result;
   end Sextets;

   Sextet_Of : constant Sextet_Table := Sextets;

   type Byte_Array is array (Natural range <>) of Unsigned_8;
   subtype Salt_Bytes is Byte_Array (0 .. 15);
   subtype Raw_Hash is Byte_Array (0 .. 23);

   --  "$2b$10$" followed by 22 salt characters: everything in a hash before the digest.
   Setting_Length     : constant := 29;
   Salt_Text_Length   : constant := 22;
   Digest_Text_Length : constant := 31; --  bcrypt encodes 23 of the 24 raw bytes

   ---------------------------------------------------------------------------------------------------------------
   --  Blowfish with the expensive key schedule (EksBlowfish)

   type Cipher_State is record
      Subkeys : Subkey_Array;
      S_Boxes : S_Box_Array;
   end record;

   -------------
   -- Feistel --
   -------------

   function Feistel (State : Cipher_State; Half : Unsigned_32) return Unsigned_32 is
     (((State.S_Boxes (0) (Unsigned_8 (Shift_Right (Half, 24)))
        + State.S_Boxes (1) (Unsigned_8 (Shift_Right (Half, 16) and 255)))
       xor State.S_Boxes (2) (Unsigned_8 (Shift_Right (Half, 8) and 255)))
      + State.S_Boxes (3) (Unsigned_8 (Half and 255)))
     with Inline;

   --------------
   -- Encipher --
   --------------

   procedure Encipher (State : Cipher_State; Left, Right : in out Unsigned_32) with Inline is
      Even : Unsigned_32 := Left xor State.Subkeys (0);
      Odd  : Unsigned_32 := Right;
   begin
      for Round in 0 .. 7 loop
         Odd  := Odd xor Feistel (State, Even) xor State.Subkeys (2 * Round + 1);
         Even := Even xor Feistel (State, Odd) xor State.Subkeys (2 * Round + 2);
      end loop;
      Left  := Odd xor State.Subkeys (17);
      Right := Even;
   end Encipher;

   ---------------
   -- Next_Word --
   ---------------

   --  The next four bytes of Data as a big-endian word, wrapping around at the end.
   procedure Next_Word (Data : Byte_Array; Position : in out Natural; Word : out Unsigned_32)
      with Inline,
           Pre  => Data'Length > 0 and then Data'Last < Natural'Last and then Position < Data'Length,
           Post => Position < Data'Length
   is begin
      Word := 0;
      for Count in 1 .. 4 loop
         pragma Loop_Invariant (Position < Data'Length);
         Word     := Shift_Left (Word, 8) or Unsigned_32 (Data (Data'First + Position));
         Position := (if Position = Data'Length - 1 then 0 else Position + 1);
      end loop;
   end Next_Word;

   -------------
   -- Mix_Key --
   -------------

   procedure Mix_Key (State : in out Cipher_State; Key : Byte_Array)
      with Inline, Pre => Key'Length > 0 and then Key'Last < Natural'Last
   is
      Position : Natural := 0;
      Word     : Unsigned_32;
   begin
      for Subkey of State.Subkeys loop
         pragma Loop_Invariant (Position < Key'Length);
         Next_Word (Key, Position, Word);
         Subkey := Subkey xor Word;
      end loop;
   end Mix_Key;

   --------------------------
   -- Expand_Key_With_Salt --
   --------------------------

   --  Key words are mixed into the subkeys once; the salt keeps cycling through every block. Only the first
   --  expansion uses a salt; the 2 ** cost expansions after it do not.
   procedure Expand_Key_With_Salt (State : in out Cipher_State; Salt : Byte_Array; Key : Byte_Array)
      with Pre => Salt'Length > 0
                  and then Salt'Last < Natural'Last
                  and then Key'Length > 0
                  and then Key'Last < Natural'Last
   is
      Position    : Natural := 0;
      Left, Right : Unsigned_32 := 0;

      --------------
      -- Mix_Salt --
      --------------

      --  The next two salt words into the block.
      procedure Mix_Salt
         with Pre  => Salt'Length > 0
                      and then Salt'Last < Natural'Last
                      and then Position < Salt'Length,
              Post => Position < Salt'Length
      is
         Word : Unsigned_32;
      begin
         Next_Word (Salt, Position, Word);
         Left  := Left xor Word;
         Next_Word (Salt, Position, Word);
         Right := Right xor Word;
      end Mix_Salt;
   begin
      Mix_Key (State, Key);

      for Pair in 0 .. 8 loop
         pragma Loop_Invariant (Position < Salt'Length);
         Mix_Salt;
         Encipher (State, Left, Right);
         State.Subkeys (2 * Pair)     := Left;
         State.Subkeys (2 * Pair + 1) := Right;
      end loop;

      for Box of State.S_Boxes loop
         pragma Loop_Invariant (Position < Salt'Length);
         for Pair in Unsigned_8 range 0 .. 127 loop
            pragma Loop_Invariant (Position < Salt'Length);
            Mix_Salt;
            Encipher (State, Left, Right);
            Box (2 * Pair)     := Left;
            Box (2 * Pair + 1) := Right;
         end loop;
      end loop;
   end Expand_Key_With_Salt;

   type Key_Bytes is record
      Bytes  : Byte_Array (0 .. Max_Password_Length - 1);
      Length : Positive range 1 .. Max_Password_Length;
   end record;

   ------------
   -- Key_Of --
   ------------

   --  The password's bytes and a NUL as a key, cut to its first 72 bytes.
   function Key_Of (Password : String) return Key_Bytes is
      Key : Key_Bytes :=
        (Bytes  => [others => 0],
         Length => Natural'Min (Password'Length, Max_Password_Length - 1) + 1);
   begin
      for Position in 0 .. Key.Length - 1 loop
         if Position < Password'Length then
            Key.Bytes (Position) := Character'Pos (Password (Password'First + Position));
         end if;
      end loop;
      return Key;
   end Key_Of;

   Initial_State : constant Cipher_State := (Subkeys => Initial_Subkeys, S_Boxes => Initial_S_Boxes);
   Magic         : constant String (1 .. 24) := "OrpheanBeholderScryDoubt";

   ------------
   -- Digest --
   ------------

   --  The magic text enciphered 64 times by the expanded State.
   function Digest (State : Cipher_State) return Raw_Hash is
      Words  : array (0 .. 5) of Unsigned_32 := [others => 0];
      Result : Raw_Hash := [others => 0];
   begin
      for Word in Words'Range loop
         Words (Word) := Shift_Left (Unsigned_32 (Character'Pos (Magic (4 * Word + 1))), 24)
           or Shift_Left (Unsigned_32 (Character'Pos (Magic (4 * Word + 2))), 16)
           or Shift_Left (Unsigned_32 (Character'Pos (Magic (4 * Word + 3))), 8)
           or Unsigned_32 (Character'Pos (Magic (4 * Word + 4)));
      end loop;

      for Round in 1 .. 64 loop
         for Pair in 0 .. 2 loop
            Encipher (State, Words (2 * Pair), Words (2 * Pair + 1));
         end loop;
      end loop;

      for Word in Words'Range loop
         Result (4 * Word)     := Unsigned_8 (Shift_Right (Words (Word), 24));
         Result (4 * Word + 1) := Unsigned_8 (Shift_Right (Words (Word), 16) and 255);
         Result (4 * Word + 2) := Unsigned_8 (Shift_Right (Words (Word), 8) and 255);
         Result (4 * Word + 3) := Unsigned_8 (Words (Word) and 255);
      end loop;

      return Result;
   end Digest;

   type Key_List  is array (Positive range <>) of Key_Bytes;
   type Salt_List is array (Positive range <>) of Salt_Bytes;
   type Raw_List  is array (Positive range <>) of Raw_Hash;

   ---------------------
   -- Raw_Interleaved --
   ---------------------

   --  The raw hashes of Width keys of the same cost, computed together. One key's Feistel rounds are a chain of
   --  dependent table loads that leaves most of the core idle; interleaving the rounds of several keys fills that
   --  time, so six keys take about 1.5 times as long as one.
   generic
      Width : Positive;
   procedure Raw_Interleaved (Keys : Key_List; Salts : Salt_List; Cost : Cost_Factor; Results : out Raw_List)
      with Pre => Keys'First = 1
                  and then Keys'Last = Width
                  and then Salts'First = 1
                  and then Salts'Last = Width
                  and then Results'First = 1
                  and then Results'Last = Width;

   procedure Raw_Interleaved (Keys : Key_List; Salts : Salt_List; Cost : Cost_Factor; Results : out Raw_List) is
      type State_List is array (1 .. Width) of Cipher_State;
      type Word_List is array (1 .. Width) of Unsigned_32;

      --  One array holds every lane's state, so the compiler knows a store to one lane's tables leaves the
      --  others' alone and need not reload them. Encipher_All and Expand_All take it as a parameter.
      Ciphers : State_List := [others => Initial_State];

      ------------------
      -- Encipher_All --
      ------------------

      procedure Encipher_All (States : State_List; Left, Right : in out Word_List)
         with Inline, Global => null   --  a contract, so GNATprove proves it once rather than at each call
      is
         Even, Odd : Word_List;
      begin
         for Lane in States'Range loop
            Even (Lane) := Left (Lane) xor States (Lane).Subkeys (0);
            Odd (Lane)  := Right (Lane);
         end loop;

         for Round in 0 .. 7 loop
            for Lane in States'Range loop
               Odd (Lane) := Odd (Lane) xor Feistel (States (Lane), Even (Lane))
                             xor States (Lane).Subkeys (2 * Round + 1);
            end loop;
            for Lane in States'Range loop
               Even (Lane) := Even (Lane) xor Feistel (States (Lane), Odd (Lane))
                              xor States (Lane).Subkeys (2 * Round + 2);
            end loop;
         end loop;

         for Lane in States'Range loop
            Left (Lane)  := Odd (Lane) xor States (Lane).Subkeys (17);
            Right (Lane) := Even (Lane);
         end loop;
      end Encipher_All;

      ----------------
      -- Expand_All --
      ----------------

      --  One unsalted key expansion of every lane, with its key or (With_Salt) its salt.
      procedure Expand_All (States : in out State_List; With_Salt : Boolean)
         with Global => (Keys, Salts),
              Pre    => Keys'First = 1 and then Keys'Last = Width and then Salts'First = 1 and then Salts'Last = Width
      is
         Left, Right : Word_List := [others => 0];
      begin
         for Lane in States'Range loop
            if With_Salt then
               Mix_Key (States (Lane), Salts (Lane));
            else
               Mix_Key (States (Lane), Keys (Lane).Bytes (0 .. Keys (Lane).Length - 1));
            end if;
         end loop;

         for Pair in 0 .. 8 loop
            Encipher_All (States, Left, Right);
            for Lane in States'Range loop
               States (Lane).Subkeys (2 * Pair)     := Left (Lane);
               States (Lane).Subkeys (2 * Pair + 1) := Right (Lane);
            end loop;
         end loop;

         for Box in S_Box_Array'Range loop
            for Pair in Unsigned_8 range 0 .. 127 loop
               Encipher_All (States, Left, Right);
               for Lane in States'Range loop
                  States (Lane).S_Boxes (Box) (2 * Pair)     := Left (Lane);
                  States (Lane).S_Boxes (Box) (2 * Pair + 1) := Right (Lane);
               end loop;
            end loop;
         end loop;
      end Expand_All;
   begin
      for Lane in Ciphers'Range loop
         Expand_Key_With_Salt (Ciphers (Lane), Salts (Lane), Keys (Lane).Bytes (0 .. Keys (Lane).Length - 1));
      end loop;

      for Round in 1 .. Unsigned_64 (2) ** Natural (Cost) loop
         Expand_All (Ciphers, With_Salt => False);
         Expand_All (Ciphers, With_Salt => True);
      end loop;

      Results := [others => [others => 0]];
      for Lane in Ciphers'Range loop
         Results (Lane) := Digest (Ciphers (Lane));
      end loop;
   end Raw_Interleaved;

   procedure Raw_1 is new Raw_Interleaved (1);
   procedure Raw_2 is new Raw_Interleaved (2);
   procedure Raw_3 is new Raw_Interleaved (3);
   procedure Raw_4 is new Raw_Interleaved (4);
   procedure Raw_5 is new Raw_Interleaved (5);
   procedure Raw_6 is new Raw_Interleaved (6);

   ---------
   -- Raw --
   ---------

   --  Results (Lane) is the raw hash of Keys (Lane) with Salts (Lane), every lane at once.
   procedure Raw (Keys : Key_List; Salts : Salt_List; Cost : Cost_Factor; Results : out Raw_List)
      with Pre => Keys'First = 1
                  and then Keys'Last in 1 .. Max_Batch
                  and then Salts'First = 1
                  and then Salts'Last = Keys'Last
                  and then Results'First = 1
                  and then Results'Last = Keys'Last
   is begin
      case Keys'Last is
         when 1      => Raw_1 (Keys, Salts, Cost, Results);
         when 2      => Raw_2 (Keys, Salts, Cost, Results);
         when 3      => Raw_3 (Keys, Salts, Cost, Results);
         when 4      => Raw_4 (Keys, Salts, Cost, Results);
         when 5      => Raw_5 (Keys, Salts, Cost, Results);
         when others => Raw_6 (Keys, Salts, Cost, Results);
      end case;
   end Raw;

   ---------------------------------------------------------------------------------------------------------------
   --  text forms

   ------------
   -- Encode --
   ------------

   function Encode (Data : Byte_Array; Length : Natural) return String
      with Pre  => Data'Length <= 32,
           Post => Encode'Result'First = 1 and then Encode'Result'Length = Length
   is
      Result  : String (1 .. Length) := [others => '.'];
      Last    : Natural := 0;
      Pending : Unsigned_32 := 0;
      Bits    : Natural := 0;   --  pending bits not yet written, below 6 until Result is full
   begin
      for Byte of Data loop
         pragma Loop_Invariant (Last <= Length and then (Bits < 6 or else Last = Length) and then Bits <= 8 * 32);
         Pending := Shift_Left (Pending, 8) or Unsigned_32 (Byte);
         Bits    := (if Last = Length then 0 else Bits + 8);
         while Bits >= 6 and then Last < Length loop
            pragma Loop_Invariant (Last < Length and then Bits in 6 .. 13);
            pragma Loop_Variant (Decreases => Bits);
            Bits          := Bits - 6;
            Last          := Last + 1;
            Result (Last) := Alphabet (Natural (Shift_Right (Pending, Bits) and 63) + 1);
         end loop;
      end loop;

      if Last < Length then
         Last          := Last + 1;
         Result (Last) := Alphabet (Natural (Shift_Left (Pending, 6 - Bits) and 63) + 1);
      end if;

      return Result;
   end Encode;

   -----------------
   -- Decode_Salt --
   -----------------

   procedure Decode_Salt (Text : String; Salt : out Salt_Bytes; Valid : out Boolean) is
      Pending : Unsigned_32 := 0;
      Bits    : Natural range 0 .. 13 := 0;
      Next    : Natural := Salt'First;
   begin
      Salt  := [others => 0];
      Valid := False;

      for Symbol of Text loop
         pragma Loop_Invariant (Bits < 8 and then Next in Salt'First .. Salt'Last + 1);
         if Sextet_Of (Symbol) = No_Sextet then
            return;
         end if;

         Pending := Shift_Left (Pending, 6) or Unsigned_32 (Sextet_Of (Symbol));
         Bits    := Bits + 6;
         if Bits >= 8 then
            Bits := Bits - 8;
            if Next <= Salt'Last then
               Salt (Next) := Unsigned_8 (Shift_Right (Pending, Bits) and 255);
               Next        := Next + 1;
            end if;
         end if;
      end loop;

      Valid := Next > Salt'Last;
   end Decode_Salt;

   --  The cost and salt read from a hash's "$2?$NN$<salt>" prefix.
   type Setting (Valid : Boolean := False) is record
      case Valid is
         when True =>
            Cost : Cost_Factor;
            Salt : Salt_Bytes;
         when False =>
            null;
      end case;
   end record;

   -------------------
   -- Parse_Setting --
   -------------------

   function Parse_Setting (Text : String) return Setting
      with Pre => Text'Length >= Setting_Length
   is
      First : constant Positive := Text'First;
      Salt  : Salt_Bytes;
      Cost  : Natural;
      Valid : Boolean;
   begin
      if Text (First .. First + 1) /= "$2"
        or else Text (First + 2) not in 'a' | 'b' | 'y' or else Text (First + 3) /= '$'
        or else Text (First + 4) not in '0' .. '3' or else Text (First + 5) not in '0' .. '9'
        or else Text (First + 6) /= '$'
      then
         return (Valid => False);
      end if;

      Cost := (Character'Pos (Text (First + 4)) - Character'Pos ('0')) * 10
            +  Character'Pos (Text (First + 5)) - Character'Pos ('0');

      if Cost not in Natural (Cost_Factor'First) .. Natural (Cost_Factor'Last) then
         return (Valid => False);
      end if;

      Decode_Salt (Text (First + 7 .. First + 6 + Salt_Text_Length), Salt, Valid);
      if not Valid then
         return (Valid => False);
      end if;

      return (Valid => True, Cost => Cost_Factor (Cost), Salt => Salt);
   end Parse_Setting;

   ----------
   -- Hash --
   ----------

   function Hash (Password : String; Random : Salt_Source; Cost : Cost_Factor := Default_Cost) return Hash_Text is
      Salt    : Salt_Bytes;
      Digests : Raw_List (1 .. 1);
      Result  : Hash_Text := [others => '.']; --  for flow analysis: every slice is written below
   begin
      for Position in Salt'Range loop
         Salt (Position) := Character'Pos (Random (Random'First + Position));
      end loop;

      Raw ([1 => Key_Of (Password)], [1 => Salt], Cost, Digests);

      Result (1 .. 4)                            := "$2b$";
      Result (5)                                 := Character'Val (Character'Pos ('0') + Natural (Cost) / 10);
      Result (6)                                 := Character'Val (Character'Pos ('0') + Natural (Cost) mod 10);
      Result (7)                                 := '$';
      Result (8 .. Setting_Length)               := Encode (Salt, Salt_Text_Length);
      Result (Setting_Length + 1 .. Hash_Length) := Encode (Digests (1) (0 .. 22), Digest_Text_Length);
      return Result;
   end Hash;

   -------------
   -- Matches --
   -------------

   --  Whether Stored's digest is Digest, in constant time.
   function Matches (Stored : String; Digest : Raw_Hash) return Boolean
      with Pre => Stored'Length = Hash_Length
   is
      Expected : constant String :=
        Stored (Stored'First .. Stored'First + Setting_Length - 1) & Encode (Digest (0 .. 22), Digest_Text_Length);
   begin
      return Sha256.Constant_Time_Equal (Expected, Stored);
   end Matches;

   ------------
   -- Verify --
   ------------

   function Verify (Password : String; Stored : String) return Boolean is
      Digests : Raw_List (1 .. 1);
   begin
      if Stored'Length /= Hash_Length then
         return False;
      end if;

      declare
         Parsed : constant Setting := Parse_Setting (Stored);
      begin
         if not Parsed.Valid then
            return False;
         end if;

         Raw ([1 => Key_Of (Password)], [1 => Parsed.Salt], Parsed.Cost, Digests);
         return Matches (Stored, Digests (1));
      end;
   end Verify;

   ------------------
   -- Verify_Batch --
   ------------------

   procedure Verify_Batch (Logins : in out Login_List) is
      type Setting_List is array (Logins'Range) of Setting;
      type Flag_List is array (Logins'Range) of Boolean;

      Parsed : Setting_List := [others => (Valid => False)];
      Done   : Flag_List    := [others => True];
   begin
      for Index in Logins'Range loop
         pragma Loop_Invariant (for all Other in Logins'Range => Done (Other) or else Parsed (Other).Valid);
         Parsed (Index)       := Parse_Setting (Logins (Index).Stored);
         Done (Index)         := not Parsed (Index).Valid;
         Logins (Index).Match := False;
      end loop;

      --  Each pass computes every login left with the first one's cost (all of them, unless costs differ).
      for First in Logins'Range loop
         pragma Loop_Invariant (for all Index in Logins'Range => Done (Index) or else Parsed (Index).Valid);

         if not Done (First) then
            declare
               Cost    : constant Cost_Factor := Parsed (First).Cost;
               Keys    : Key_List (1 .. Max_Batch)  := [others => (Bytes => [others => 0], Length => 1)];
               Salts   : Salt_List (1 .. Max_Batch) := [others => [others => 0]];
               Owners  : array (1 .. Max_Batch) of Positive := [others => First];
               Digests : Raw_List (1 .. Max_Batch)  := [others => [others => 0]];
               Count   : Natural := 0;
            begin
               for Index in First .. Logins'Last loop
                  pragma Loop_Invariant (Count <= Index - First
                                         and then (if Index > First then Count >= 1)
                                         and then (for all Taken in 1 .. Count => Owners (Taken) in Logins'Range)
                                         and then (for all Other in Logins'Range =>
                                                     Done (Other) or else Parsed (Other).Valid));
                  if not Done (Index) and then Parsed (Index).Cost = Cost then
                     Count          := Count + 1;
                     Keys (Count)   := Key_Of (Logins (Index).Password (1 .. Logins (Index).Length));
                     Salts (Count)  := Parsed (Index).Salt;
                     Owners (Count) := Index;
                     Done (Index)   := True;
                  end if;
               end loop;

               Raw (Keys (1 .. Count), Salts (1 .. Count), Cost, Digests (1 .. Count));
               for Taken in 1 .. Count loop
                  Logins (Owners (Taken)).Match := Matches (Logins (Owners (Taken)).Stored, Digests (Taken));
               end loop;
            end;
         end if;
      end loop;
   end Verify_Batch;

end Bcrypt;
