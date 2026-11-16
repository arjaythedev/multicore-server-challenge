--  Decoding Postgres protocol bytes (binary format) held in a receive buffer. Every length the server sends is
--  checked against the bytes around it once, when a row is framed; the value accessors are total, so a field
--  that does not fit reads as NULL, 0 or "" instead of reaching outside the buffer.
--
--  Proved free of run-time errors (SPARK silver), whatever bytes arrive.
with Interfaces; use Interfaces;

package Postgres_Wire with SPARK_Mode is

   Null_Length : constant := -1;

   Max_Buffer_Length : constant := 2 ** 30;

   --  A receive buffer as the decoder sees it.
   function Framed (Data : String) return Boolean is (Data'First = 1 and then Data'Last in 0 .. Max_Buffer_Length);

   --  A value inside the buffer: Length bytes from Position, or SQL NULL.
   type Field is record
      Position : Positive := 1;
      Length   : Integer range Null_Length .. Integer'Last := Null_Length;
   end record;

   Null_Field : constant Field := (Position => 1, Length => Null_Length);

   function Is_Null (Item : Field) return Boolean is (Item.Length = Null_Length);

   --  Whether Item is a value whose bytes lie inside Data.
   function Inside (Data : String; Item : Field) return Boolean is
     (Item.Length >= 0 and then Item.Position >= Data'First and then Item.Length <= Data'Last - Item.Position + 1)
   with Pre => Framed (Data);

   --  Big-endian integers at Position.
   function Word (Data : String; Position : Positive) return Unsigned_32
      with Pre => Framed (Data) and then Position <= Data'Last - 3;

   function Short (Data : String; Position : Positive) return Natural
      with Pre => Framed (Data) and then Position <= Data'Last - 1, Post => Short'Result < 2 ** 16;

   --  The next column of a DataRow at Position: a signed length (-1 for NULL), then the bytes. Valid when the
   --  length is -1 or more and the bytes end by Last; Position then moves past them.
   procedure Next_Column (Data     : String;
                          Last     : Natural;
                          Position : in out Positive;
                          Item     : out Field;
                          Valid    : out Boolean)
      with Pre  => Framed (Data) and then Last <= Data'Last,
           Post => (if Valid 
                    then (Is_Null (Item) or else Inside (Data, Item))
                          and then Position <= Last + 1
                          and then Position > Position'Old);

   --  Field Code ('C' the SQLSTATE, 'M' the message) of an ErrorResponse whose fields are Data (First .. Last).
   function Error_Field (Data : String; First : Positive; Last : Natural; Code : Character) return String
      with Pre => Framed (Data) and then Last <= Data'Last;

   --  Values: total over any field.
   function Text (Data : String; Item : Field) return String
      with Pre => Framed (Data);

   function Integer_Value (Data : String; Item : Field) return Long_Long_Integer   --  int8; 0 unless 8 bytes
      with Pre => Framed (Data);

   function Boolean_Value (Data : String; Item : Field) return Boolean
      with Pre => Framed (Data);

   --  Binary arrays (one dimension): dimensions, has-nulls flag, element type, then length and lower bound, then
   --  each element as a length and its bytes.
   function Element_Count (Data : String; Item : Field) return Natural
      with Pre => Framed (Data);

   --  Element Index (from 1); a NULL field when the array has no such element or its framing is broken.
   function Element (Data : String; Item : Field; Index : Positive) return Field
      with Pre  => Framed (Data),
           Post => Is_Null (Element'Result) or else Inside (Data, Element'Result);

end Postgres_Wire;
