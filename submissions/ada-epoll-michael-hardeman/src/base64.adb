package body Base64 with SPARK_Mode is

   subtype Sextet is Natural range 0 .. 63;
   type Character_Table is array (Sextet) of Character;

   Characters : constant array (Alphabet) of Character_Table :=
     [Standard => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
      Url_Safe => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];

   ------------
   -- Encode --
   ------------

   function Encode (Data : String; Using : Alphabet := Standard) return String is
      Table  : Character_Table renames Characters (Using);
      Groups : constant Natural := Data'Length / 3;    --  whole three-byte groups
      Rest   : constant Natural := Data'Length mod 3;  --  bytes after them
      Result : String (1 .. (Data'Length + 2) / 3 * 4) := [others => '='];
      Last   : Natural := 0;

      ----------
      -- Byte --
      ----------

      function Byte (Position : Positive) return Natural is (Character'Pos (Data (Position)))
      with Pre => Position in Data'Range;
   begin
      for Group in 0 .. Groups - 1 loop
         pragma Loop_Invariant (Last = Group * 4);
         declare
            Next : constant Positive := Data'First + Group * 3;
         begin
            pragma Assert (Next + 2 <= Data'Last);
            Result (Last + 1) := Table (Byte (Next) / 4);
            Result (Last + 2) := Table (Byte (Next) mod 4 * 16 + Byte (Next + 1) / 16);
            Result (Last + 3) := Table (Byte (Next + 1) mod 16 * 4 + Byte (Next + 2) / 64);
            Result (Last + 4) := Table (Byte (Next + 2) mod 64);
            Last              := Last + 4;
         end;
      end loop;

      pragma Assert (Last = Groups * 4);
      if Rest > 0 then
         declare
            Next : constant Positive := Data'First + Groups * 3;
         begin
            Result (Last + 1) := Table (Byte (Next) / 4);
            if Rest = 1 then
               Result (Last + 2) := Table (Byte (Next) mod 4 * 16);
               Last              := Last + 2;
            else
               Result (Last + 2) := Table (Byte (Next) mod 4 * 16 + Byte (Next + 1) / 16);
               Result (Last + 3) := Table (Byte (Next + 1) mod 16 * 4);
               Last              := Last + 3;
            end if;
         end;
         if Using = Standard then
            Last := Result'Last;   --  the rest of the group is the '=' padding already there
         end if;
      end if;

      return Result (1 .. Last);
   end Encode;

   No_Sextet : constant := -1;
   type Value_Table is array (Character) of Integer range No_Sextet .. Sextet'Last;

   ---------------
   -- Values_Of --
   ---------------

   function Values_Of (Table : Character_Table) return Value_Table is
      Result : Value_Table := [others => No_Sextet];
   begin
      for Value in Table'Range loop
         Result (Table (Value)) := Value;
      end loop;
      return Result;
   end Values_Of;

   Values : constant array (Alphabet) of Value_Table :=
     [Standard => Values_Of (Characters (Standard)), Url_Safe => Values_Of (Characters (Url_Safe))];

   ------------
   -- Decode --
   ------------

   procedure Decode (Text  : String;
                     Data  : out String;
                     Last  : out Natural;
                     Valid : out Boolean;
                     Using : Alphabet := Standard)
   is
      Table   : Value_Table renames Values (Using);
      Pending : Natural := 0;                  --  holds the Bits waiting for the next character
      Bits    : Natural range 0 .. 6 := 0;     --  0, 2, 4 or 6
      Length  : Natural := Text'Length;        --  without the '=' padding

      ----------------
      -- Holds_Bits --
      ----------------

      function Holds_Bits return Boolean is
        (case Bits is
            when 0      => Pending = 0,
            when 2      => Pending < 4,
            when 4      => Pending < 16,
            when 6      => Pending < 64,
            when others => False);
   begin
      Data  := [others => ASCII.NUL];
      Last  := Data'First - 1;
      Valid := False;

      while Length > 0 and then Text (Text'First + (Length - 1)) = '=' loop
         pragma Loop_Invariant (Length <= Text'Length);
         pragma Loop_Variant (Decreases => Length);
         Length := Length - 1;
      end loop;

      if Length mod 4 = 1 then
         return;
      end if;

      for Position in Text'First .. Text'First - 1 + Length loop
         pragma Loop_Invariant (Holds_Bits and then (Last = Data'First - 1 or else Last in Data'Range));
         declare
            Value : constant Integer := Table (Text (Position));
            Byte  : Natural range 0 .. 255;
         begin
            if Value = No_Sextet then
               return;
            end if;

            if Bits = 0 then
               Pending := Value;
               Bits    := 6;
            else
               if Last >= Data'Last then
                  return;
               end if;
               case Bits is
                  when 2 =>
                     Byte    := Pending * 64 + Value;
                     Pending := 0;
                  when 4 =>
                     Byte    := Pending * 16 + Value / 4;
                     Pending := Value mod 4;
                  when others =>
                     Byte    := Pending * 4 + Value / 16;
                     Pending := Value mod 16;
               end case;
               Bits        := Bits - 2;
               Last        := Last + 1;
               Data (Last) := Character'Val (Byte);
            end if;
         end;
      end loop;

      Valid := True;
      end Decode;

end Base64;
