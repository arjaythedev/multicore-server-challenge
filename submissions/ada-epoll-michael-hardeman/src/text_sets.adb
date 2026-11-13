with Ada.Unchecked_Deallocation;

package body Text_Sets with SPARK_Mode is

   procedure Deallocate is new Ada.Unchecked_Deallocation (Contents, Contents_Access);

   ----------
   -- Hash --
   ----------

   --  FNV-1a.
   function Hash (Item : String) return Unsigned_64 is
      Result : Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Symbol of Item loop
         Result := (Result xor Character'Pos (Symbol)) * 16#0100_0000_01B3#;
      end loop;

      return Result;
      end Hash;

   -------------
   -- Text_Of --
   -------------

   function Text_Of (Data : Contents; Position : Positive) return String is
     (if Data.Pool.Data = null or else Data.Firsts (Position) > Data.Lasts (Position) then ""
      else Data.Pool.Data (Data.Firsts (Position) .. Data.Lasts (Position)))
      with Pre => Well_Formed (Data) and then Position <= Data.Count;

   -------------
   -- Element --
   -------------

   function Element (This : Set; Position : Positive) return String is (Text_Of (This.Data.all, Position));

   ----------
   -- Home --
   ----------

   function Home (Data : Contents; Code : Unsigned_64) return Natural is
     (Natural (Code mod Unsigned_64 (Data.Table_Last + 1)))
      with Post => Home'Result <= Data.Table_Last;

   ---------------
   -- Next_Slot --
   ---------------

   function Next_Slot (Data : Contents; Slot : Natural) return Natural is
     (if Slot >= Data.Table_Last then 0 else Slot + 1)
      with Post => Next_Slot'Result <= Data.Table_Last;

   No_Slot : constant Integer := -1;

   -------------
   -- Slot_Of --
   -------------

   --  The slot holding Item, or the free slot where it would go; No_Slot when neither was found.
   function Slot_Of (Data : Contents; Item : String; Code : Unsigned_64) return Integer
      with Pre  => Well_Formed (Data),
           Post => Slot_Of'Result = No_Slot or else Slot_Of'Result in 0 .. Data.Table_Last
   is
      Slot : Natural := Home (Data, Code);
   begin
      for Probe in 0 .. Data.Table_Last loop
         pragma Loop_Invariant (Slot <= Data.Table_Last);
         declare
            Position : constant Natural := Data.Table (Slot);
         begin
            if Position = 0
              or else (Data.Hashes (Position) = Code and then Text_Of (Data, Position) = Item)
            then
               return Slot;
            end if;
         end;
         Slot := Next_Slot (Data, Slot);
      end loop;

      return No_Slot;
   end Slot_Of;

   ----------
   -- Find --
   ----------

   function Find (This : Set; Item : String) return Natural is
      Slot : Integer;
   begin
      if This.Data = null then
         return 0;
      end if;

      Slot := Slot_Of (This.Data.all, Item, Hash (Item));
      return (if Slot = No_Slot then 0 else This.Data.Table (Slot));
   end Find;

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Set) is begin
      if This.Data /= null then
         Free (This.Data.Pool);
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
         Free (This.Data.Pool);
         Deallocate (This.Data);
      end if;

      while Table_Last < 2 * Room loop
         pragma Loop_Invariant (Table_Last in 15 .. 4 * Max_Capacity);
         pragma Loop_Variant (Increases => Table_Last);
         Table_Last := 2 * Table_Last + 1;
      end loop;

      This.Data := new Contents'(Capacity   => Room,
                                 Table_Last => Table_Last,
                                 Firsts     => [others => 1],
                                 Lasts      => [others => 0],
                                 Hashes     => [others => 0],
                                 Table      => [others => 0],
                                 Count      => 0,
                                 Pool       => (Data => null, Length => 0, Overflowed => False));
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
         Clear (This.Data.Pool);
      else
         Create (This, Natural'Min (Max_Capacity, Room + Room / 2));
      end if;
   end Reset;

   ---------
   -- Add --
   ---------

   procedure Add (This : in out Set; Item : String; Position : out Natural) is
      Code : constant Unsigned_64 := Hash (Item);
      Slot : Integer;
   begin
      Position := 0;
      if This.Data = null then
         return;
      end if;

      Slot := Slot_Of (This.Data.all, Item, Code);
      if Slot = No_Slot then
         return;
      elsif This.Data.Table (Slot) /= 0 then
         Position := This.Data.Table (Slot);
         return;
      elsif This.Data.Count = This.Data.Capacity or else Item'Length > Max_Capacity - This.Data.Pool.Length then
         return;   --  full
      end if;

      declare
         First     : constant Positive := This.Data.Pool.Length + 1;
         New_Count : constant Positive := This.Data.Count + 1;
      begin
         Append (This.Data.Pool, Item);
         pragma Assert (for all Other in This.Data.Table'Range => This.Data.Table (Other) < New_Count);
         This.Data.Firsts (New_Count) := First;
         This.Data.Lasts (New_Count)  := This.Data.Pool.Length;
         This.Data.Hashes (New_Count) := Code;
         This.Data.Table (Slot)       := New_Count;
         This.Data.Count              := New_Count;
         Position                     := New_Count;
      end;
   end Add;

end Text_Sets;
