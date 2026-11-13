with Base64; use Base64;
with Json; use Json;
with Settings;
with Sha256;

package body Jwt with SPARK_Mode is

   Key : constant Sha256.Hmac_Key := Sha256.To_Hmac_Key (Settings.Secret);

   Encoded_Header : constant String := Encode ("{""alg"":""HS256"",""typ"":""JWT""}", Url_Safe);

   Lifetime : constant Unix_Seconds := 30 * 24 * 3600;

   -----------
   -- Image --
   -----------

   --  The decimal digits of a non-negative Value.
   function Image (Value : Long_Long_Integer) return String
      with Pre  => Value >= 0,
           Post => Image'Result'Length in 1 .. 19
   is
      Text     : String (1 .. 19) := [others => '0'];
      Position : Positive;
      Rest     : Long_Long_Integer := Value;
   begin
      for Count in 1 .. Text'Length loop
         pragma Loop_Invariant (Rest >= 0);
         Position        := Text'Last + 1 - Count;
         Text (Position) := Character'Val (Character'Pos ('0') + Rest mod 10);
         Rest            := Rest / 10;
         exit when Rest = 0;
      end loop;

      return Text (Position .. Text'Last);
   end Image;

   ----------
   -- Sign --
   ----------

   function Sign (User : Known_User; Now : Unix_Seconds) return String is
      Claims : constant String :=
        "{""sub"":""" & Image (Long_Long_Integer (User)) & """,""iat"":" & Image (Long_Long_Integer (Now))
        & ",""exp"":" & Image (Long_Long_Integer (Now + Lifetime)) & "}";
      Signed : constant String := Encoded_Header & "." & Encode (Claims, Url_Safe);
   begin
      return Signed & "." & Encode (Sha256.Hmac (Key, Signed), Url_Safe);
   end Sign;

   --  A JSON number as whole seconds, rounded down; magnitudes above Limit saturate.
   type Seconds_Claim (Valid : Boolean := False) is record
      case Valid is
         when True  => Seconds : Unix_Seconds;
         when False => null;
      end case;
   end record;

   Limit : constant := 10 ** 15;

   ----------------
   -- Seconds_Of --
   ----------------

   function Seconds_Of (Text : String) return Seconds_Claim is
      Precision   : constant := 10 ** 17; --  significant digits kept: below this, one more fits
      Max_Scale   : constant := 100_000;  --  far beyond what can change a saturated or zero result
      Position    : Natural := 0;         --  offset of the next character
      Negative    : Boolean := False;
      Significand : Long_Long_Integer := 0;
      Scale       : Integer range -2 * Max_Scale .. 2 * Max_Scale := 0; --  value = significand * 10 ** scale
      Exponent    : Natural := 0;
      Inexact     : Boolean := False;     --  a non-zero digit was dropped
      Seen        : Boolean := False;
      Magnitude   : Long_Long_Integer;

      -------------
      -- Next_Is --
      -------------

      function Next_Is (Symbols : String) return Boolean is
        (Position < Text'Length and then (for some Symbol of Symbols => Text (Text'First + Position) = Symbol));

      -----------
      -- Digit --
      -----------

      function Digit return Natural is (Character'Pos (Text (Text'First + Position)) - Character'Pos ('0'))
         with Pre => Position < Text'Length and then Text (Text'First + Position) in '0' .. '9';

      --------------
      -- Is_Digit --
      --------------

      function Is_Digit return Boolean is (Position < Text'Length and then Text (Text'First + Position) in '0' .. '9');
   begin
      if Next_Is ("-") then
         Negative := True;
         Position := Position + 1;
      end if;

      while Is_Digit loop   --  whole part
         pragma Loop_Invariant (Significand in 0 .. Precision * 10 - 1 and then Scale in 0 .. Max_Scale);
         pragma Loop_Variant (Increases => Position);
         Seen := True;
         if Significand < Precision then
            Significand := Significand * 10 + Long_Long_Integer (Digit);
         else
            Scale   := Integer'Min (Scale + 1, Max_Scale);
            Inexact := Inexact or else Digit /= 0;
         end if;
         Position := Position + 1;
      end loop;

      if not Seen then
         return (Valid => False);
      end if;

      if Next_Is (".") then   --  fraction
         Position := Position + 1;
         if not Is_Digit then
            return (Valid => False);
         end if;
         while Is_Digit loop
            pragma Loop_Invariant (Significand in 0 .. Precision * 10 - 1 and then Scale in -Max_Scale .. Max_Scale);
            pragma Loop_Variant (Increases => Position);
            if Significand < Precision and then Scale > -Max_Scale then
               Significand := Significand * 10 + Long_Long_Integer (Digit);
               Scale       := Scale - 1;
            else
               Inexact := Inexact or else Digit /= 0;
            end if;
            Position := Position + 1;
         end loop;
      end if;

      if Next_Is ("eE") then   --  exponent
         Position := Position + 1;
         declare
            Below : constant Boolean := Next_Is ("-");
         begin
            if Below or else Next_Is ("+") then
               Position := Position + 1;
            end if;
            if not Is_Digit then
               return (Valid => False);
            end if;
            while Is_Digit loop
               pragma Loop_Invariant (Exponent <= Max_Scale and then Scale in -Max_Scale .. Max_Scale);
               pragma Loop_Variant (Increases => Position);
               Exponent := Integer'Min (Exponent * 10 + Digit, Max_Scale);
               Position := Position + 1;
            end loop;
            Scale := (if Below then Scale - Exponent else Scale + Exponent);
         end;
      end if;

      if Position /= Text'Length then
         return (Valid => False);
      end if;

      Magnitude := Significand;
      if Scale > 0 then
         for Step in 1 .. Scale loop
            pragma Loop_Invariant (Magnitude in 0 .. Precision * 10 - 1);
            exit when Magnitude = 0 or else Magnitude > Limit;
            Magnitude := Magnitude * 10;
         end loop;
      else
         for Step in 1 .. -Scale loop
            pragma Loop_Invariant (Magnitude in 0 .. Precision * 10 - 1);
            exit when Magnitude = 0;
            Inexact   := Inexact or else Magnitude mod 10 /= 0;
            Magnitude := Magnitude / 10;
         end loop;
      end if;

      if Magnitude >= Limit then
         return (Valid => True, Seconds => (if Negative then -Limit else Limit));
      elsif Negative then
         return (Valid => True, Seconds => Unix_Seconds (-Magnitude - (if Inexact then 1 else 0)));
      else
         return (Valid => True, Seconds => Unix_Seconds (Magnitude));
      end if;
   end Seconds_Of;

   ----------------
   -- Subject_Of --
   ----------------

   --  The positive integer a "sub" claim holds: 1 to 18 digits, not zero.
   function Subject_Of (Text : String) return Verdict is
      --  10 ** N, spelled out so the loop invariant needs no exponentiation.
      Powers : constant array (0 .. 18) of Long_Long_Integer :=
        [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
         10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000,
         1_000_000_000_000_000, 10_000_000_000_000_000, 100_000_000_000_000_000,
         1_000_000_000_000_000_000];
      Id : Long_Long_Integer := 0;
   begin
      if Text'Length not in 1 .. 18 or else (for some Symbol of Text => Symbol not in '0' .. '9') then
         return (Valid => False);
      end if;

      pragma Assert (for all N in 0 .. 17 => Powers (N + 1) = Powers (N) * 10);
      for Offset in 0 .. Text'Length - 1 loop
         pragma Loop_Invariant (Id in 0 .. Powers (Offset) - 1);
         Id := Id * 10 + (Character'Pos (Text (Text'First + Offset)) - Character'Pos ('0'));
      end loop;

      if Id = 0 then
         return (Valid => False);
      end if;
      return (Valid => True, User => Known_User (Id));
   end Subject_Of;

   ------------
   -- Verify --
   ------------

   function Verify (Token : String; Now : Unix_Seconds) return Verdict is
      Rejected : constant Verdict := (Valid => False);
      First_Dot, Second_Dot : Natural := 0;
   begin
      if Token'Length > Max_Token_Length then
         return Rejected;
      end if;

      for Position in Token'Range loop
         pragma Loop_Invariant
           (First_Dot in 0 | Token'First .. Position - 1
            and then Second_Dot in 0 | First_Dot + 1 .. Position - 1
            and then (if Second_Dot /= 0 then First_Dot /= 0));
         if Token (Position) = '.' then
            if First_Dot = 0 then
               First_Dot := Position;
            elsif Second_Dot = 0 then
               Second_Dot := Position;
            else
               return Rejected;
            end if;
         end if;
      end loop;

      if Second_Dot = 0 then
         return Rejected;
      end if;

      --  The signature first: nothing else in the token is trusted until it matches.
      declare
         Signature : String (1 .. 48);
         Last      : Natural;
         Valid     : Boolean;
      begin
         Decode (Token (Second_Dot + 1 .. Token'Last), Signature, Last, Valid, Url_Safe);
         if not Valid or else Last /= Sha256.Digest'Length
           or else not Sha256.Constant_Time_Equal (Left  => Signature (Sha256.Digest'Range),
                                                   Right => Sha256.Hmac (Key, Token (Token'First .. Second_Dot - 1)))
         then
            return Rejected;
         end if;
      end;

      declare
         Segment : String (1 .. Decoded_Length (Token'Length));
         Claims  : Document (Node_Capacity => 64, Text_Capacity => Token'Length + 16);

         -------------------
         -- Parse_Segment --
         -------------------

         --  Decode and parse one base64url segment into Claims.
         procedure Parse_Segment (Encoded : String; Valid : out Boolean) is
            Last : Natural;
         begin
            Decode (Encoded, Segment, Last, Valid, Url_Safe);
            if Valid then
               Parse (Claims, Segment (1 .. Last), Valid);
            end if;
         end Parse_Segment;

         -------------
         -- Seconds --
         -------------

         function Seconds (Name : String) return Seconds_Claim is
           (if Kind_Of (Claims, Member (Claims, Root, Name)) = Number_Kind
            then Seconds_Of (Value (Claims, Member (Claims, Root, Name)))
            else (Valid => False));

         Valid : Boolean;
      begin
         Parse_Segment (Token (Token'First .. First_Dot - 1), Valid);
         if not Valid then
            return Rejected;
         end if;

         declare
            Algorithm : constant Node_Count := Member (Claims, Root, "alg");
         begin
            if Kind_Of (Claims, Algorithm) /= String_Kind or else Value (Claims, Algorithm) /= "HS256" then
               return Rejected;
            end if;
         end;

         Parse_Segment (Token (First_Dot + 1 .. Second_Dot - 1), Valid);
         if not Valid then
            return Rejected;
         end if;

         declare
            Expires : constant Seconds_Claim := Seconds ("exp");
         begin
            if not Expires.Valid or else Expires.Seconds <= Now then
               return Rejected;
            end if;
         end;

         if Member (Claims, Root, "nbf") /= No_Node then
            declare
               Not_Before : constant Seconds_Claim := Seconds ("nbf");
            begin
               if not Not_Before.Valid or else Not_Before.Seconds > Now then
                  return Rejected;
               end if;
            end;
         end if;

         declare
            Subject : constant Node_Count := Member (Claims, Root, "sub");
         begin
            if Kind_Of (Claims, Subject) /= String_Kind then
               return Rejected;
            end if;

            return Subject_Of (Value (Claims, Subject));
         end;
      end;
   end Verify;

end Jwt;
