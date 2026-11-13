--  Rows of a statement result gathered into groups (the rows of each page, of each comment thread), each group
--  in row order or by a key, descending. Rows are added, then the groups are closed and read. Every read is
--  total.
--
--  Proved free of run-time errors (SPARK silver).
package Row_Groups with SPARK_Mode is

   Max_Rows : constant := 2 ** 24;

   type Groups is limited private;   --  no groups until Create

   --  Whether This holds no memory (so it may go out of scope).
   function Reclaimed (This : Groups) return Boolean;

   --  Group_Count groups, room for Room rows in all; any earlier contents are released.
   procedure Create (This : in out Groups; Group_Count : Natural; Room : Natural)
      with Pre => Group_Count <= Max_Rows and then Room <= Max_Rows;

   --  Empty again, with Group_Count groups and room for at least Room rows. The memory is kept when it is big
   --  enough and not more than four times too big; otherwise it is replaced, with half as much room again to
   --  spare.
   procedure Reset (This : in out Groups; Group_Count : Natural; Room : Natural)
      with Pre => Group_Count <= Max_Rows and then Room <= Max_Rows;

   --  Row into Group, ordered by Key; nothing when Group is not one of the groups or there is no room.
   procedure Add (This : in out Groups; Group : Long_Long_Integer; Row : Positive; Key : Long_Long_Integer := 0);

   --  Arrange the rows by group, each group in the order added or by Key, descending.
   procedure Close (This : in out Groups; By_Key_Descending : Boolean);

   function Size (This : Groups; Group : Positive) return Natural;
   function Row (This : Groups; Group : Positive; Index : Positive) return Positive;   --  1 outside the group

   procedure Free (This : in out Groups) with Post => Reclaimed (This);

private

   type Natural_Array is array (Positive range <>) of Natural;
   type Key_Array is array (Positive range <>) of Long_Long_Integer;

   subtype Row_Range is Natural range 0 .. Max_Rows;

   type Contents (Group_Count : Row_Range; Room : Row_Range) is record
      Used        : Row_Range;                          --  groups 1 .. Used take rows
      Added       : Natural;                            --  rows added
      Group_Of    : Natural_Array (1 .. Room);
      Row_Of      : Natural_Array (1 .. Room);
      Key_Of      : Key_Array (1 .. Room);
      Starts      : Natural_Array (1 .. Group_Count);   --  after Close, group G's rows are
      Counts      : Natural_Array (1 .. Group_Count);   --  Sorted (Starts (G) .. Starts (G) + Counts (G) - 1)
      Sorted      : Natural_Array (1 .. Room);
      Sorted_Keys : Key_Array (1 .. Room);
   end record;

   type Contents_Access is access Contents;

   type Groups is limited record
      Data : Contents_Access;
   end record;

   function Reclaimed (This : Groups) return Boolean is (This.Data = null);

end Row_Groups;
