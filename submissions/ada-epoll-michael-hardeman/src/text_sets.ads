--  Distinct texts in the order they were added, each with a position (1, 2, ...): Index_Sets for strings. The
--  texts are copied into one pool that grows as needed.
--
--  Proved free of run-time errors (SPARK silver).
with Interfaces; use Interfaces;
with Buffers; use Buffers;

package Text_Sets with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   Max_Capacity : constant := 2 ** 24;
   subtype Capacity_Range is Natural range 0 .. Max_Capacity;

   type Set is limited private;   --  empty, with no capacity, until Create

   --  Whether This holds no memory (so it may go out of scope).
   function Reclaimed (This : Set) return Boolean;

   function Capacity (This : Set) return Capacity_Range;
   function Length (This : Set) return Natural with Post => Length'Result <= Capacity (This);

   function Element (This : Set; Position : Positive) return String with Pre => Position <= Length (This);

   --  Item's position, or 0 when it is not in the set.
   function Find (This : Set; Item : String) return Natural with Post => Find'Result <= Length (This);

   --  An empty set with room for Room texts; any earlier contents are released.
   procedure Create (This : in out Set; Room : Capacity_Range)
      with Post => Length (This) = 0 and then Capacity (This) = Room;

   --  Empty again, with room for at least Room texts. The memory is kept when it is big enough and not more
   --  than four times too big; otherwise it is replaced, with half as much room again to spare.
   procedure Reset (This : in out Set; Room : Capacity_Range)
      with Post => Length (This) = 0 and then Capacity (This) >= Room;

   --  Item's position, adding it when it is new; 0 when it is new and there is no room for it.
   procedure Add (This : in out Set; Item : String; Position : out Natural)
      with Post => Position <= Length (This) and then Capacity (This) = Capacity (This)'Old
                   and then Length (This) >= Length (This)'Old;

   procedure Free (This : in out Set) with Post => Capacity (This) = 0 and then Reclaimed (This);

private

   subtype Table_Range is Natural range 0 .. 8 * Max_Capacity;

   type Natural_Array is array (Natural range <>) of Natural;
   type Hash_Array is array (Positive range <>) of Unsigned_64;

   type Contents (Capacity : Capacity_Range; Table_Last : Table_Range) is record
      Firsts : Natural_Array (1 .. Capacity);   --  text Position is Pool (Firsts (Position) .. Lasts (Position))
      Lasts  : Natural_Array (1 .. Capacity);
      Hashes : Hash_Array (1 .. Capacity);
      Table  : Natural_Array (0 .. Table_Last);   --  a position, or 0 for a free slot
      Count  : Natural;
      Pool   : Buffer;
   end record;

   type Contents_Access is access Contents;

   type Set is limited record
      Data : Contents_Access;
   end record
   with Type_Invariant => Set.Data = null or else Well_Formed (Set.Data.all);

   function Well_Formed (Data : Contents) return Boolean is
     (Data.Count <= Data.Capacity and then Data.Table_Last >= Data.Capacity and then Valid (Data.Pool)
      and then (for all Slot in Data.Table'Range => Data.Table (Slot) <= Data.Count)
      and then (for all Position in 1 .. Data.Count =>
                  Data.Firsts (Position) >= 1 and then Data.Lasts (Position) <= Data.Pool.Length
                  and then Data.Firsts (Position) <= Data.Lasts (Position) + 1));

   function Capacity (This : Set) return Capacity_Range is (if This.Data = null then 0 else This.Data.Capacity);

   function Length (This : Set) return Natural is (if This.Data = null then 0 else This.Data.Count);

   function Reclaimed (This : Set) return Boolean is (This.Data = null);

end Text_Sets;
