with Ada.Unchecked_Deallocation;

package body Index_Sets with SPARK_Mode is

   pragma Unevaluated_Use_Of_Old (Allow);

   procedure Deallocate is new Ada.Unchecked_Deallocation (Contents, Contents_Access);

   -------------
   -- Element --
   -------------

   function Element (This : Set; Position : Positive) return Key is (This.Data.Keys (Position));

   -----------
   -- Value --
   -----------

   function Value (This : Set; Position : Positive) return Item_Value is (This.Data.Values (Position));

   ----------
   -- Home --
   ----------

   --  Where Item's probe sequence starts.
   function Home (Data : Contents; Item : Key) return Natural is
     (Natural (Hash (Item) mod Unsigned_64 (Data.Table_Last + 1)))
      with Post => Home'Result <= Data.Table_Last;

   ---------------
   -- Next_Slot --
   ---------------

   function Next_Slot (Data : Contents; Slot : Natural) return Natural is
     (if Slot >= Data.Table_Last then 0 else Slot + 1)
      with Post => Next_Slot'Result <= Data.Table_Last;

   ----------
   -- Find --
   ----------

   function Find (This : Set; Item : Key) return Natural is
      Slot : Natural;
   begin
      if This.Data = null then
         return 0;
      end if;

      Slot := Home (This.Data.all, Item);
      for Probe in 0 .. This.Data.Table_Last loop
         pragma Loop_Invariant (Slot <= This.Data.Table_Last);
         declare
            Position : constant Natural := This.Data.Table (Slot);
         begin
            if Position = 0 then
               return 0;
            elsif This.Data.Keys (Position) = Item then
               return Position;
            end if;
         end;
         Slot := Next_Slot (This.Data.all, Slot);
      end loop;

      return 0;
   end Find;

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Set) is begin
      if This.Data /= null then
         Deallocate (This.Data);
      end if;
   end Free;

   ------------
   -- Create --
   ------------

   procedure Create (This : in out Set; Room : Capacity_Range) is
      Table_Last : Natural := 15;
   begin
      if This.Data /= null then
         Deallocate (This.Data);
      end if;

      while Table_Last < 2 * Room loop
         pragma Loop_Invariant (Table_Last in 15 .. 4 * Max_Capacity);
         pragma Loop_Variant (Increases => Table_Last);
         Table_Last := 2 * Table_Last + 1;
      end loop;

      This.Data := new Contents'(Capacity   => Room,
                                 Table_Last => Table_Last,
                                 Keys       => [others => Empty],
                                 Values     => [others => No_Value],
                                 Table      => [others => 0],
                                 Count      => 0);
   end Create;

   -----------
   -- Reset --
   -----------

   procedure Reset (This : in out Set; Room : Capacity_Range) is begin
      if This.Data /= null and then This.Data.Capacity >= Room
        and then This.Data.Capacity / 4 <= Natural'Max (Room, 256)
      then
         This.Data.Table := [others => 0];
         This.Data.Count := 0;
      else
         Create (This, Natural'Min (Max_Capacity, Room + Room / 2));
      end if;
   end Reset;

   ---------
   -- Add --
   ---------

   procedure Add (This : in out Set; Item : Key; Position : out Natural; Value : Item_Value := No_Value) is
      Slot : Natural;
   begin
      Position := 0;
      if This.Data = null then
         return;
      end if;

      Slot := Home (This.Data.all, Item);
      for Probe in 0 .. This.Data.Table_Last loop
         pragma Loop_Invariant (Slot <= This.Data.Table_Last and then Well_Formed (This.Data.all)
                                and then This.Data.Count = This.Data.Count'Loop_Entry);
         declare
            Found : constant Natural := This.Data.Table (Slot);
         begin
            if Found = 0 then
               if This.Data.Count = This.Data.Capacity then
                  return;   --  full
               end if;
               declare
                  New_Count : constant Positive := This.Data.Count + 1;
               begin
                  pragma Assert (for all Other in This.Data.Table'Range => This.Data.Table (Other) < New_Count);
                  This.Data.Keys (New_Count)   := Item;
                  This.Data.Values (New_Count) := Value;
                  This.Data.Table (Slot)       := New_Count;
                  This.Data.Count              := New_Count;
                  pragma Assert (Well_Formed (This.Data.all));
                  Position := New_Count;
               end;
               return;
            elsif This.Data.Keys (Found) = Item then
               Position := Found;
               return;
            end if;
         end;
         Slot := Next_Slot (This.Data.all, Slot);
      end loop;
   end Add;

   -------------
   -- Include --
   -------------

   procedure Include (This : in out Set; Item : Key; Value : Item_Value := No_Value) is
      Ignored : Natural;
   begin
      Add (This, Item, Ignored, Value);
   end Include;

end Index_Sets;
