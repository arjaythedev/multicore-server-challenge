with Ada.Unchecked_Deallocation;

package body Buffers with SPARK_Mode is

   procedure Deallocate is new Ada.Unchecked_Deallocation (String, String_Access);

   ----------
   -- Free --
   ----------

   procedure Free (Text : in out String_Access) is begin
      if Text /= null then
         Deallocate (Text);
      end if;
   end Free;

   procedure Deallocate is new Ada.Unchecked_Deallocation (String_List, String_List_Access);

   ----------
   -- Free --
   ----------

   procedure Free (List : in out String_List_Access) is begin
      if List /= null then
         for Index in List'Range loop
            Free (List (Index));
            pragma Loop_Invariant (for all Earlier in List'First .. Index => List (Earlier) = null);
         end loop;
         Deallocate (List);
      end if;
   end Free;

   --------------
   -- Allocate --
   --------------

   procedure Allocate (Into : in out Buffer; Capacity : Positive) is begin
      if Buffers.Capacity (Into) < Capacity then
         pragma Warnings (GNATprove, Off, "statement has no effect",
                          Reason => "frees the old block before replacing it");
         pragma Warnings (GNATprove, Off, "* is set by * but not used after the call", Reason => "same");
         Free (Into.Data);
         pragma Warnings (GNATprove, On, "statement has no effect");
         pragma Warnings (GNATprove, On, "* is set by * but not used after the call");
         Into.Data := new String'(1 .. Capacity => ' ');
      end if;

      Into.Length     := 0;
      Into.Overflowed := False;
   end Allocate;

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Buffer) is begin
      Free (This.Data);
      This.Length     := 0;
      This.Overflowed := False;
   end Free;

   -----------
   -- Clear --
   -----------

   procedure Clear (This : in out Buffer) is begin
      This.Length     := 0;
      This.Overflowed := False;
   end Clear;

   -------------
   -- Restart --
   -------------

   procedure Restart (This : in out Buffer) is begin
      if not Valid (This) then
         Free (This.Data);
      end if;

      This.Length     := 0;
      This.Overflowed := False;
   end Restart;

   ----------
   -- Grow --
   ----------

   --  A larger block holding the content: at least Needed bytes, doubling from the current capacity.
   procedure Grow (This : in out Buffer; Needed : Positive)
   with
     Pre  => Valid (This) and then Needed <= Max_Capacity and then Needed > Capacity (This),
     Post => Valid (This) and then This.Length = This.Length'Old and then Capacity (This) >= Needed
   is
      New_Capacity : Positive := Positive'Max (Capacity (This), 256);
      Larger       : String_Access;
   begin
      while New_Capacity < Needed loop
         pragma Loop_Invariant (New_Capacity < Needed);
         pragma Loop_Variant (Increases => New_Capacity);
         New_Capacity := (if New_Capacity > Max_Capacity / 2 then Max_Capacity else New_Capacity * 2);
      end loop;

      New_Capacity := Positive'Min (New_Capacity, Max_Capacity);
      Larger       := new String'(1 .. New_Capacity => ' ');
      if This.Data /= null then
         Larger (1 .. This.Length) := This.Data (1 .. This.Length);
         Deallocate (This.Data);
      end if;

      This.Data := Larger;
   end Grow;

   -------------
   -- Reserve --
   -------------

   procedure Reserve (This : in out Buffer; Extra : Natural) is begin
      if Extra <= Max_Capacity - This.Length and then This.Length + Extra > Capacity (This) then
         Grow (This, This.Length + Extra);
      end if;
   end Reserve;

   ------------
   -- Extend --
   ------------

   procedure Extend (This : in out Buffer; Count : Natural) is begin
      This.Length := This.Length + Count;
   end Extend;

   --------------
   -- Truncate --
   --------------

   procedure Truncate (This : in out Buffer; Length : Natural) is begin
      This.Length := Length;
   end Truncate;

   -------------
   -- Consume --
   -------------

   procedure Consume (This : in out Buffer; Count : Natural) is
      Remaining : constant Natural := This.Length - Count;
   begin
      if Remaining > 0 then
         This.Data (1 .. Remaining) := This.Data (Count + 1 .. This.Length);
      end if;
      This.Length := Remaining;
   end Consume;

   ------------
   -- Append --
   ------------

   procedure Append (To : in out Buffer; Text : String) is begin
      Reserve (To, Text'Length);
      if Text'Length > Capacity (To) - To.Length then
         To.Overflowed := True;
         return;
      end if;

      if Text'Length > 0 then
         To.Data (To.Length + 1 .. To.Length + Text'Length) := Text;
         To.Length := To.Length + Text'Length;
      end if;
   end Append;

   ------------
   -- Append --
   ------------

   procedure Append (To : in out Buffer; Byte : Character) is begin
      Reserve (To, 1);
      if Capacity (To) = To.Length then
         To.Overflowed := True;
         return;
      end if;

      To.Length           := To.Length + 1;
      To.Data (To.Length) := Byte;
   end Append;

   --------------------
   -- Append_Integer --
   --------------------

   procedure Append_Integer (To : in out Buffer; Value : Long_Long_Integer) is begin
      Append (To, Decimal_Image (Value));
   end Append_Integer;

   ----------
   -- Byte --
   ----------

   function Byte (Value : Unsigned_64; Shift : Natural) return Character is
     (Character'Val (Shift_Right (Value, Shift) and 255)) with Inline;

   --------------------
   -- Append_Exactly --
   --------------------

   --  Bytes all at once, or none and Overflowed.
   procedure Append_Exactly (To : in out Buffer; Bytes : String)
      with Inline,
           Pre  => Valid (To) and then Bytes'Length in 1 .. 8,
           Post => Valid (To) and then (if not To.Overflowed 
                                        then To.Length = To.Length'Old + Bytes'Length 
                                        else To.Length >= To.Length'Old)
   is begin
      Reserve (To, Bytes'Length);
      if Bytes'Length > Capacity (To) - To.Length then
         To.Overflowed := True;
         return;
      end if;

      To.Data (To.Length + 1 .. To.Length + Bytes'Length) := Bytes;
      To.Length := To.Length + Bytes'Length;
   end Append_Exactly;

   -----------------------
   -- Append_Big_Endian --
   -----------------------

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_16) is begin
      Append_Exactly (To, [Byte (Unsigned_64 (Value), 8), Byte (Unsigned_64 (Value), 0)]);
   end Append_Big_Endian;

   -----------------------
   -- Append_Big_Endian --
   -----------------------

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_32) is
      Wide : constant Unsigned_64 := Unsigned_64 (Value);
   begin
      Append_Exactly (To, [Byte (Wide, 24), Byte (Wide, 16), Byte (Wide, 8), Byte (Wide, 0)]);
   end Append_Big_Endian;

   -----------------------
   -- Append_Big_Endian --
   -----------------------

   procedure Append_Big_Endian (To : in out Buffer; Value : Unsigned_64) is begin
      Append_Exactly (To, [Byte (Value, 56), Byte (Value, 48), Byte (Value, 40), Byte (Value, 32),
                           Byte (Value, 24), Byte (Value, 16), Byte (Value, 8), Byte (Value, 0)]);
   end Append_Big_Endian;

   --------------------------
   -- Overwrite_Big_Endian --
   --------------------------

   procedure Overwrite_Big_Endian (This : in out Buffer; Position : Positive; Value : Unsigned_32) is
      Wide : constant Unsigned_64 := Unsigned_64 (Value);
   begin
      This.Data (Position .. Position + 3) := [Byte (Wide, 24), Byte (Wide, 16), Byte (Wide, 8), Byte (Wide, 0)];
   end Overwrite_Big_Endian;

   ------------------------
   -- Append_Json_String --
   ------------------------

   procedure Append_Json_String (To : in out Buffer; Text : String) is begin
      if Text'Length > Formatting.Max_Text_Length then
         To.Overflowed := True;
         return;
      end if;

      declare
         Needed : constant Positive := Formatting.Escaped_Length (Text);
      begin
         Reserve (To, Needed);
         if Needed > Capacity (To) - To.Length then
            To.Overflowed := True;
            return;
         end if;

         Formatting.Escape (Text, To.Data.all, To.Length);   --  proved to write exactly what was reserved
      end;
   end Append_Json_String;

   ----------------------
   -- Append_Timestamp --
   ----------------------

   procedure Append_Timestamp (To : in out Buffer; Time : Postgres_Timestamp) is begin
      Append (To, '"');
      Append (To, Formatting.Timestamp (Time));
      Append (To, '"');
   end Append_Timestamp;

end Buffers;
