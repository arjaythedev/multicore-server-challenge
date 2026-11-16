package body Settings with SPARK_Mode is

   ---------------
   -- Is_Digits --
   ---------------

   function Is_Digits (Text : String) return Boolean is
     (Text'Length > 0 and then (for all Symbol of Text => Symbol in '0' .. '9'));

   -----------
   -- Value --
   -----------

   --  The decimal value of 1 to 9 digits.
   function Value (Text : String) return Natural
      with Pre => Is_Digits (Text) and then Text'Length <= 9
   is
      Powers : constant array (0 .. 9) of Natural :=
        [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000];
      Result : Natural := 0;
   begin
      pragma Assert (for all N in 0 .. 8 => Powers (N + 1) = Powers (N) * 10);
      for Index in Text'Range loop
         pragma Loop_Invariant (Index - Text'First <= 8 and then Result <= Powers (Index - Text'First) - 1);
         Result := Result * 10 + (Character'Pos (Text (Index)) - Character'Pos ('0'));
      end loop;
      return Result;
   end Value;

   type Parsed_Address is record
      Valid   : Boolean := False;
      Address : IPv4_Address := 0;
   end record;

   ----------------
   -- Address_Of --
   ----------------

   --  "a.b.c.d", "localhost" or "::" (every address).
   function Address_Of (Text : String) return Parsed_Address is
      Start  : Natural := Text'First;
      Part   : Natural := 0;
      Result : IPv4_Address := 0;
   begin
      if Text = "::" then
         return (True, Any_Address);
      elsif Text = "localhost" then
         return (True, Loopback);
      elsif Text'Last = Positive'Last then
         return (False, 0);
      end if;
      for Index in Text'First .. Text'Last + 1 loop
         pragma Loop_Invariant (Start in Text'First .. Index and then Part <= 3);
         if Index > Text'Last or else Text (Index) = '.' then
            declare
               Octet : constant String := Text (Start .. Index - 1);
            begin
               if not Is_Digits (Octet) or else Octet'Length > 3 or else Value (Octet) > 255 then
                  return (False, 0);
               end if;
               Result := Result * 256 + IPv4_Address (Value (Octet));
            end;
            if Index > Text'Last then
               return (Part = 3, Result);
            elsif Part = 3 then
               return (False, 0);
            end if;
            Part  := Part + 1;
            Start := Index + 1;
         end if;
      end loop;
      return (False, 0);
   end Address_Of;

   ------------------
   -- Small_Number --
   ------------------

   function Small_Number (Text : String; Last : Natural) return Boolean is
     (Is_Digits (Text) and then Text'Length <= 6 and then Value (Text) <= Last);

   Parsed_Host  : constant Parsed_Address := Address_Of (Host);
   Port_Valid   : constant Boolean := Small_Number (Port_Image, Natural (Port_Number'Last));
   Window_Valid : constant Boolean := Small_Number (Window_Image, 1000);

   -----------------
   -- First_Bytes --
   -----------------

   function First_Bytes (Text : String) return String is
     (Text (Text'First .. Text'First - 1 + Natural'Min (Text'Length, 100)));

   -----------
   -- Valid --
   -----------

   function Valid return Boolean is
     (Secret'Length > 0 and then Parsed_Host.Valid and then Port_Valid and then Window_Valid);

   -------------
   -- Problem --
   -------------

   function Problem return String is
     (if Secret'Length = 0 then "JWT_SECRET is not set"
      elsif not Parsed_Host.Valid then "HOST must be an IPv4 address: " & First_Bytes (Host)
      elsif not Port_Valid then "PORT is not a port number: " & First_Bytes (Port_Image)
      elsif not Window_Valid then "READ_WINDOW_MS must be 0 to 1000"
      else "");

   -------------
   -- Address --
   -------------

   function Address return IPv4_Address is (Parsed_Host.Address);

   ----------
   -- Port --
   ----------

   function Port return Port_Number is (if Port_Valid then Port_Number (Value (Port_Image)) else 3000);

   -----------------
   -- Read_Window --
   -----------------

   function Read_Window return Milliseconds is (if Window_Valid then Milliseconds (Value (Window_Image)) else 10);

end Settings;
