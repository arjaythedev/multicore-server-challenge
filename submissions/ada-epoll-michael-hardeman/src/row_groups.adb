with Ada.Unchecked_Deallocation;

package body Row_Groups with SPARK_Mode is

   procedure Deallocate is new Ada.Unchecked_Deallocation (Contents, Contents_Access);

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Groups) is begin
      if This.Data /= null then
         Deallocate (This.Data);
      end if;
   end Free;

   --------------
   -- Allocate --
   --------------

   procedure Allocate (This : in out Groups; Group_Count, Room, Used : Row_Range) is begin
      if This.Data /= null then
         Deallocate (This.Data);
      end if;

      This.Data := new Contents'(Group_Count => Group_Count,
                                 Room        => Room,
                                 Used        => Used,
                                 Added       => 0,
                                 Group_Of    => [others => 0],
                                 Row_Of      => [others => 0],
                                 Key_Of      => [others => 0],
                                 Starts      => [others => 0],
                                 Counts      => [others => 0],
                                 Sorted      => [others => 0],
                                 Sorted_Keys => [others => 0]);
   end Allocate;

   ------------
   -- Create --
   ------------

   procedure Create (This : in out Groups; Group_Count : Natural; Room : Natural) is begin
      Allocate (This, Group_Count, Room, Group_Count);
   end Create;

   -----------
   -- Reset --
   -----------

   procedure Reset (This : in out Groups; Group_Count : Natural; Room : Natural) is begin
      if This.Data /= null and then This.Data.Group_Count >= Group_Count and then This.Data.Room >= Room
        and then This.Data.Group_Count / 4 <= Natural'Max (Group_Count, 256)
        and then This.Data.Room / 4 <= Natural'Max (Room, 256)
      then
         This.Data.Used   := Group_Count;
         This.Data.Added  := 0;
         This.Data.Starts := [others => 0];
         This.Data.Counts := [others => 0];
      else
         Allocate (This        => This,
                   Group_Count => Natural'Min (Max_Rows, Group_Count + Group_Count / 2),
                   Room        => Natural'Min (Max_Rows, Room + Room / 2),
                   Used        => Group_Count);
      end if;
   end Reset;

   ---------
   -- Add --
   ---------

   procedure Add (This : in out Groups; Group : Long_Long_Integer; Row : Positive; Key : Long_Long_Integer := 0)
   is begin
      if This.Data = null
        or else Group not in 1 .. Long_Long_Integer (Natural'Min (This.Data.Used, This.Data.Group_Count))
        or else This.Data.Added >= This.Data.Room
      then
         return;
      end if;

      This.Data.Added                      := This.Data.Added + 1;
      This.Data.Group_Of (This.Data.Added) := Natural (Group);
      This.Data.Row_Of (This.Data.Added)   := Row;
      This.Data.Key_Of (This.Data.Added)   := Key;
   end Add;

   -------------
   -- Arrange --
   -------------

   procedure Arrange (Data : in out Contents; Group_Count : Row_Range; By_Key_Descending : Boolean)
      with Pre => Group_Count = Data.Group_Count
   is
      Next : Natural := 1;
   begin
      declare
         Fill : Natural_Array (1 .. Group_Count) := [others => 0];
      begin
         Data.Counts := [others => 0];
         for Index in 1 .. Natural'Min (Data.Added, Data.Room) loop
            if Data.Group_Of (Index) in 1 .. Data.Group_Count
              and then Data.Counts (Data.Group_Of (Index)) < Data.Room
            then
               Data.Counts (Data.Group_Of (Index)) := Data.Counts (Data.Group_Of (Index)) + 1;
            end if;
         end loop;

         for Group in 1 .. Data.Group_Count loop   --  each group's first place
            pragma Loop_Invariant (Next in 1 .. Data.Room + 1);
            Data.Starts (Group) := Next;
            Next                := Natural'Min (Next + Natural'Min (Data.Counts (Group), Data.Room), Data.Room + 1);
         end loop;

         for Index in 1 .. Natural'Min (Data.Added, Data.Room) loop   --  in order of addition, so stable
            declare
               Group : constant Natural := Data.Group_Of (Index);
            begin
               if Group in 1 .. Data.Group_Count and then Fill (Group) < Data.Counts (Group)
                 and then Data.Starts (Group) in 1 .. Data.Room - Fill (Group)
               then
                  Data.Sorted (Data.Starts (Group) + Fill (Group))      := Data.Row_Of (Index);
                  Data.Sorted_Keys (Data.Starts (Group) + Fill (Group)) := Data.Key_Of (Index);
                  Fill (Group)                                          := Fill (Group) + 1;
               end if;
            end;
         end loop;

         Data.Counts := Fill;   --  what was placed

         if By_Key_Descending then
            for Group in 1 .. Data.Group_Count loop
               declare
                  First : constant Natural := Data.Starts (Group);
               begin
                  --  insertion sort: groups are short and usually in order already
                  if First >= 1 and then Data.Counts (Group) <= Data.Room
                    and then First <= Data.Room - Data.Counts (Group)
                  then
                     for Next_Index in First + 1 .. First + Data.Counts (Group) - 1 loop
                        declare
                           Moving_Row : constant Natural := Data.Sorted (Next_Index);
                           Moving_Key : constant Long_Long_Integer := Data.Sorted_Keys (Next_Index);
                           Hole       : Positive := Next_Index;
                        begin
                           while Hole > First and then Data.Sorted_Keys (Hole - 1) < Moving_Key loop
                              pragma Loop_Invariant (Hole in First + 1 .. Next_Index);
                              pragma Loop_Variant (Decreases => Hole);
                              Data.Sorted (Hole)      := Data.Sorted (Hole - 1);
                              Data.Sorted_Keys (Hole) := Data.Sorted_Keys (Hole - 1);
                              Hole                    := Hole - 1;
                           end loop;
                           Data.Sorted (Hole)      := Moving_Row;
                           Data.Sorted_Keys (Hole) := Moving_Key;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
         end if;
      end;
   end Arrange;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Groups; By_Key_Descending : Boolean) is begin
      if This.Data /= null then
         Arrange (This.Data.all, This.Data.Group_Count, By_Key_Descending);
      end if;
   end Close;

   ----------
   -- Size --
   ----------

   function Size (This : Groups; Group : Positive) return Natural is
     (if This.Data = null or else Group > This.Data.Group_Count then 0 else This.Data.Counts (Group));

   ---------
   -- Row --
   ---------

   function Row (This : Groups; Group : Positive; Index : Positive) return Positive is
     (if This.Data = null or else Group > This.Data.Group_Count or else Index > This.Data.Counts (Group)
        or else This.Data.Starts (Group) not in 1 .. This.Data.Room - Index + 1
        or else This.Data.Sorted (This.Data.Starts (Group) + Index - 1) = 0
      then 1
      else This.Data.Sorted (This.Data.Starts (Group) + Index - 1));

end Row_Groups;
