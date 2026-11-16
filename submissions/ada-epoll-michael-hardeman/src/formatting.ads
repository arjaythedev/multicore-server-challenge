--  The text formats responses are made of: decimal integers, RFC 3339 timestamps and JSON string literals.
--  Buffers stores them; this package computes them.
--
--  Proved free of run-time errors (SPARK silver), and the escaper is proved to write exactly the length it
--  announces, so a buffer reserved for that length is never overrun.
package Formatting with SPARK_Mode is

   --  Decimal digits, with a leading '-' when negative.
   function Decimal_Image (Value : Long_Long_Integer) return String
   with Post => Decimal_Image'Result'Length in 1 .. 20;

   --  Microseconds since 2000-01-01 UTC (Postgres's binary timestamptz) as RFC 3339 with milliseconds, truncated:
   --  2025-04-01T12:00:00.000Z. Years outside 0 .. 9999 keep their last four digits.
   type Postgres_Timestamp is new Long_Long_Integer;
   subtype Timestamp_Text is String (1 .. 24);
   function Timestamp (Time : Postgres_Timestamp) return Timestamp_Text;

   --  JSON string literals. Text is UTF-8; '"', '\' and control characters are escaped.
   Max_Text_Length : constant := 2 ** 27;

   --  The bytes one character takes inside the literal.
   function Width (Symbol : Character) return Positive is
     (case Symbol is
         when '"' | '\' | ASCII.LF | ASCII.CR | ASCII.HT => 2,
         when ASCII.NUL .. ASCII.BS | ASCII.VT .. ASCII.FF | ASCII.SO .. ASCII.US => 6,   --  \u00XX
         when others                                     => 1)
   with Post => Width'Result <= 6;

   --  The escaped length of Text without its quotes, as a specification.
   function Escaped_Body_Length (Text : String) return Natural is
     (if Text'Length = 0 then 0
      else Escaped_Body_Length (Text (Text'First .. Text'Last - 1)) + Width (Text (Text'Last)))
   with
     Ghost,
     Pre                => Text'Length <= Max_Text_Length,
     Post               => Escaped_Body_Length'Result <= 6 * Text'Length,
     Subprogram_Variant => (Decreases => Text'Length);

   --  The literal's length, quotes included.
   function Escaped_Length (Text : String) return Positive
   with
     Pre  => Text'Length <= Max_Text_Length,
     Post => Escaped_Length'Result = Escaped_Body_Length (Text) + 2;

   --  Write the literal into Into after Last, advancing Last past it.
   procedure Escape (Text : String; Into : in out String; Last : in out Natural)
   with
     Pre  => Text'Length <= Max_Text_Length and then Into'First = 1 and then Last <= Into'Last
             and then Into'Last - Last >= Escaped_Length (Text),
     Post => Last = Last'Old + Escaped_Length (Text);

end Formatting;
