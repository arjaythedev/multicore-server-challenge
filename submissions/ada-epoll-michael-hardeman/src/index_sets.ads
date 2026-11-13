--  Distinct keys in the order they were added, each with a position (1, 2, ...) and a value (the first given):
--  what the batch planner needs to turn a batch into SQL arrays and its rows back into answers. Open addressing
--  over a table at least twice the capacity, allocated once per batch at the size the batch needs; no element is
--  allocated on its own.
--
--  Proved free of run-time errors (SPARK silver).
with Interfaces; use Interfaces;

generic
   type Key is private;
   Empty : Key; --  what unused entries hold
   with function Hash (Item : Key) return Unsigned_64;
   type Item_Value is private;
   No_Value : Item_Value;
package Index_Sets with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   Max_Capacity : constant := 2 ** 24;
   subtype Capacity_Range is Natural range 0 .. Max_Capacity;

   type Set is limited private;   --  empty, with no capacity, until Create

   --  Whether This holds no memory (so it may go out of scope).
   function Reclaimed (This : Set) return Boolean;

   function Capacity (This : Set) return Capacity_Range;
   function Length (This : Set) return Natural with Post => Length'Result <= Capacity (This);

   function Element (This : Set; Position : Positive) return Key with Pre => Position <= Length (This);
   function Value (This : Set; Position : Positive) return Item_Value with Pre => Position <= Length (This);

   --  Item's position, or 0 when it is not in the set.
   function Find (This : Set; Item : Key) return Natural with Post => Find'Result <= Length (This);
   function Contains (This : Set; Item : Key) return Boolean is (Find (This, Item) /= 0);

   --  An empty set with room for Room keys; any earlier contents are released.
   procedure Create (This : in out Set; Room : Capacity_Range)
      with Post => Length (This) = 0 and then Capacity (This) = Room;

   --  Empty again, with room for at least Room keys. The memory is kept when it is big enough and not more
   --  than four times too big; otherwise it is replaced, with half as much room again to spare.
   procedure Reset (This : in out Set; Room : Capacity_Range)
      with Post => Length (This) = 0 and then Capacity (This) >= Room;

   --  Item's position, adding Item with Value when it is new; 0 when it is new and the set is full.
   procedure Add (This : in out Set; Item : Key; Position : out Natural; Value : Item_Value := No_Value)
      with Post => Position <= Length (This)
                   and then Capacity (This) = Capacity (This)'Old
                   and then Length (This) >= Length (This)'Old;

   procedure Include (This : in out Set; Item : Key; Value : Item_Value := No_Value)
      with Post => Capacity (This) = Capacity (This)'Old
                   and then Length (This) >= Length (This)'Old;

   procedure Free (This : in out Set) with Post => Capacity (This) = 0 and then Reclaimed (This);

private

   type Key_Array     is array (Positive range <>) of Key;
   type Natural_Array is array (Natural  range <>) of Natural;
   type Value_Array   is array (Positive range <>) of Item_Value;

   subtype Table_Range is Natural range 0 .. 8 * Max_Capacity;

   type Contents (Capacity : Capacity_Range; Table_Last : Table_Range) is record
      Keys   : Key_Array     (1 .. Capacity);
      Values : Value_Array   (1 .. Capacity);
      Table  : Natural_Array (0 .. Table_Last);   --  a position, or 0 for a free slot
      Count  : Natural;
   end record;

   type Contents_Access is access Contents;

   type Set is limited record
      Data : Contents_Access;
   end record with Type_Invariant => Set.Data = null or else Well_Formed (Set.Data.all);

   function Well_Formed (Data : Contents) return Boolean is
     (Data.Count <= Data.Capacity and then Data.Table_Last >= Data.Capacity
      and then (for all Slot in Data.Table'Range => Data.Table (Slot) <= Data.Count));

   function Capacity (This : Set) return Capacity_Range is (if This.Data = null then 0 else This.Data.Capacity);

   function Length (This : Set) return Natural is (if This.Data = null then 0 else This.Data.Count);

   function Reclaimed (This : Set) return Boolean is (This.Data = null);

end Index_Sets;
