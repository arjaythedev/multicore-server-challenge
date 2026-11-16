with Interfaces; use Interfaces;

package body Formatting with SPARK_Mode is

   -----------
   -- Digit --
   -----------

   function Digit (Value : Natural) return Character is (Character'Val (Character'Pos ('0') + Value))
      with Pre => Value <= 9;

   -------------------
   -- Decimal_Image --
   -------------------

   function Decimal_Image (Value : Long_Long_Integer) return String is
      Text      : String (1 .. 20) := [others => '0'];
      First     : Positive;
      Magnitude : Unsigned_64 := (if Value < 0 then Unsigned_64 (-(Value + 1)) + 1 else Unsigned_64 (Value));
   begin
      for Count in 1 .. 20 loop --  2 ** 64 has 20 digits
         First        := Text'Last + 1 - Count;
         Text (First) := Digit (Natural (Magnitude mod 10));
         Magnitude    := Magnitude / 10;
         exit when Magnitude = 0;
      end loop;

      if Value < 0 then
         if First = 1 then
            First := 2; --  unreachable: a negative 64-bit value has at most 19 digits
         end if;
         First        := First - 1;
         Text (First) := '-';
      end if;

      return Text (First .. Text'Last);
   end Decimal_Image;

   ---------------
   -- Timestamp --
   ---------------

   function Timestamp (Time : Postgres_Timestamp) return Timestamp_Text is
      Ms_Per_Day             : constant := 86_400_000;
      Days_From_1970_To_2000 : constant := 10_957;

      --  floor divisions: Ada's "mod" already rounds toward minus infinity
      Time_Cast    : constant Long_Long_Integer := Long_Long_Integer (Time);
      Rounding     : constant Long_Long_Integer := (if Time_Cast mod 1000 /= 0
                                                       and then Time_Cast < 0 then 1 else 0);
      Total_Ms     : constant Long_Long_Integer := Time_Cast / 1000 - Rounding;
      Day_Rounding : constant Long_Long_Integer := (if Total_Ms mod Ms_Per_Day /= 0
                                                       and then Total_Ms < 0 then 1 else 0);
      Day          : constant Long_Long_Integer := Total_Ms / Ms_Per_Day - Day_Rounding;
      Of_Day       : constant Long_Long_Integer := Total_Ms mod Ms_Per_Day;

      --  civil_from_days (Howard Hinnant's algorithm), for days since 1970-01-01
      Shifted      : constant Long_Long_Integer := Day + Days_From_1970_To_2000 + 719_468;
      Era          : constant Long_Long_Integer := (if Shifted >= 0 then Shifted else Shifted - 146_096) / 146_097;
      Day_Of_Era   : constant Long_Long_Integer := Shifted - Era * 146_097;
      Year_Of_Era  : constant Long_Long_Integer := (Day_Of_Era - Day_Of_Era / 1460 + 
                                                    Day_Of_Era / 36_524 - Day_Of_Era / 146_096) / 365;
      Day_Of_Year  : constant Long_Long_Integer := Day_Of_Era - (365 * Year_Of_Era + 
                                                   Year_Of_Era / 4 - Year_Of_Era / 100);
      March_Month  : constant Long_Long_Integer := (5 * Day_Of_Year + 2) / 153; --  0 = March
      Day_Of_Month : constant Long_Long_Integer := Day_Of_Year - (153 * March_Month + 2) / 5 + 1;
      Month        : constant Long_Long_Integer := (if March_Month < 10 then March_Month + 3 else March_Month - 9);
      Year         : constant Long_Long_Integer := Year_Of_Era + Era * 400 + (if Month <= 2 then 1 else 0);

      Text : Timestamp_Text := "0000-00-00T00:00:00.000Z";

      ---------
      -- Put --
      ---------

      --  The last Width decimal digits of Value (its magnitude) at First.
      procedure Put (First : Positive; Width : Positive; Value : Long_Long_Integer)
         with Pre => Width <= 4 and then First <= Text'Last - Width + 1
      is
         Remaining : Long_Long_Integer := Value;
      begin
         for Position in reverse First .. First + Width - 1 loop
            Text (Position) := Digit (Natural (abs (Remaining rem 10)));
            Remaining       := Remaining / 10;
         end loop;
      end Put;
   begin
      Put (1, 4, Year);
      Put (6, 2, Month);
      Put (9, 2, Day_Of_Month);
      Put (12, 2, Of_Day / 3_600_000);
      Put (15, 2, Of_Day / 60_000 mod 60);
      Put (18, 2, Of_Day / 1000 mod 60);
      Put (21, 3, Of_Day mod 1000);
      return Text;
   end Timestamp;

   -----------------------
   -- Prefix_Not_Longer --
   -----------------------

   --  A prefix of Text never escapes to more than Text does.
   procedure Prefix_Not_Longer (Text : String; Last : Integer)
      with Ghost,
           Pre                => Text'Length <= Max_Text_Length and then Last in Text'First - 1 .. Text'Last,
           Post               => Escaped_Body_Length (Text (Text'First .. Last)) <= Escaped_Body_Length (Text),
           Subprogram_Variant => (Decreases => Text'Length)
   is begin
      if Last < Text'Last then
         Prefix_Not_Longer (Text (Text'First .. Text'Last - 1), Last);
      end if;
   end Prefix_Not_Longer;

   --------------------
   -- Escaped_Length --
   --------------------

   function Escaped_Length (Text : String) return Positive is
      Count : Natural := 0;
   begin
      for Index in Text'Range loop
         pragma Loop_Invariant
           (Count = Escaped_Body_Length (Text (Text'First .. Index - 1))
            and then Count <= 6 * (Index - Text'First));
         Count := Count + Width (Text (Index));
      end loop;
      return Count + 2;
   end Escaped_Length;

   Hex_Digits : constant String (1 .. 16) := "0123456789abcdef";

   ------------
   -- Escape --
   ------------

   procedure Escape (Text : String; Into : in out String; Last : in out Natural) is
      Start : constant Natural := Last with Ghost;
      Room  : constant Natural := Escaped_Length (Text) with Ghost;

      ---------
      -- Put --
      ---------

      procedure Put (Symbol : Character)
      with Pre => Into'First = 1 and then Last < Into'Last, Post => Last = Last'Old + 1
      is begin
         Last        := Last + 1;
         Into (Last) := Symbol;
      end Put;
   begin
      Put ('"');

      for Index in Text'Range loop

         pragma Loop_Invariant (Last = Start + 1 + Escaped_Body_Length (Text (Text'First .. Index - 1)));
         Prefix_Not_Longer (Text, Index);
         pragma Assert (Into'Last - Last >= Width (Text (Index)) + 1);

         declare
            Symbol : constant Character := Text (Index);
         begin
            case Symbol is
               when '"' | '\' =>
                  Put ('\');
                  Put (Symbol);
               when ASCII.LF =>
                  Put ('\');
                  Put ('n');
               when ASCII.CR =>
                  Put ('\');
                  Put ('r');
               when ASCII.HT =>
                  Put ('\');
                  Put ('t');
               when ASCII.NUL .. ASCII.BS | ASCII.VT .. ASCII.FF | ASCII.SO .. ASCII.US =>
                  Put ('\');
                  Put ('u');
                  Put ('0');
                  Put ('0');
                  Put (Hex_Digits (Character'Pos (Symbol) / 16 + 1));
                  Put (Hex_Digits (Character'Pos (Symbol) mod 16 + 1));
               when others =>
                  Put (Symbol);
            end case;
         end;
      end loop;

      pragma Assert (Last = Start + 1 + Escaped_Body_Length (Text) and then Room = Escaped_Body_Length (Text) + 2);
      Put ('"');
   end Escape;

end Formatting;
