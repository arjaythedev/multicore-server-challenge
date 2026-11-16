with Ada.Unchecked_Deallocation;
with Buffers; use Buffers;
with Effects;
with Http; use Http;
with Jobs; use Jobs;
with Jwt;
with Model; use Model;
with Postgres; use Postgres;
with Render;
with Sql;

--  Every subprogram here is at library level with its own contract, so each is proved once, against the
--  contracts of what it calls; the per-batch state lives in the lane's Workspace and is passed explicitly.
package body Planner with SPARK_Mode is

   function "<" (Left, Right : Pair) return Boolean is
     (Left.Left < Right.Left or else (Left.Left = Right.Left and then Left.Right < Right.Right));

   type Pair_Array is array (Positive range <>) of Pair;
   type Pair_Array_Access is access Pair_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Pair_Array, Pair_Array_Access);

   type Rank_Array is array (Positive range <>) of Natural;

   ----------
   -- Swap --
   ----------

   procedure Swap (Items : in out Pair_Array; Left, Right : Positive)
      with Pre => Left in Items'Range and then Right in Items'Range
   is
      Moving : constant Pair := Items (Left);
   begin
      Items (Left)  := Items (Right);
      Items (Right) := Moving;
   end Swap;

   ---------------
   -- Sift_Down --
   ---------------

   procedure Sift_Down (Items : in out Pair_Array; Start : Positive; Last : Natural)
      with Pre => Items'First = 1
                  and then Start <= Last
                  and then Last <= Items'Last
                  and then Items'Last <= 2 ** 24
   is
      Root  : Positive := Start;
      Child : Positive;
   begin
      while 2 * Root <= Last loop
         pragma Loop_Invariant (Root <= Last);
         pragma Loop_Variant (Increases => Root);
         Child := 2 * Root;
         if Child < Last and then Items (Child) < Items (Child + 1) then
            Child := Child + 1;
         end if;
         exit when not (Items (Root) < Items (Child));
         Swap (Items, Root, Child);
         Root := Child;
      end loop;
   end Sift_Down;

   ----------
   -- Sort --
   ----------

   --  Heapsort, ascending.
   procedure Sort (Items : in out Pair_Array)
      with Pre => Items'First = 1
                  and then Items'Last <= 2 ** 24
   is begin
      for Start in reverse 1 .. Items'Last / 2 loop
         Sift_Down (Items, Start, Items'Last);
      end loop;

      for Last in reverse 2 .. Items'Last loop
         Swap (Items, 1, Last);
         Sift_Down (Items, 1, Last - 1);
      end loop;
   end Sort;

   --------------------
   -- Saturating_Sum --
   --------------------

   function Saturating_Sum (Left, Right : Natural; Limit : Natural) return Natural is
     (if Left >= Limit or else Right >= Limit - Left then Limit else Left + Right)
   with Post => Saturating_Sum'Result <= Natural'Max (Limit, Left);

   -------------
   -- Planned --
   -------------

   function Planned (Request : Ask) return Boolean is
     (case Request.Kind is
         when No_Ask    => False,
         when Tags_Ask  => True,
         when Keyed_Ask => Request.Key /= 0,
         when List_Ask  => Request.Count_Key /= 0 and then Request.Page_Key /= 0,
         when Feed_Ask  => Request.Viewer_Key /= 0 and then Request.Feed_Key /= 0);

   List_Statement_Of : constant array (Filtered) of List_Statement :=
     [By_Tag => Tag_Pages, By_Author => Author_Pages, By_Favoriter => Favoriter_Pages];

   Filter_Of : constant array (List_Statement) of Filtered :=
     [Tag_Pages => By_Tag, Author_Pages => By_Author, Favoriter_Pages => By_Favoriter];

   type Statement_Ref is not null access constant Statement;

   Statement_Of : constant array (Phase_A_Statement) of Statement_Ref :=
     [Tags            => Sql.Batch_Tags'Access,
      Users           => Sql.Batch_Users'Access,
      Logins          => Sql.Batch_Logins'Access,
      Profiles        => Sql.Batch_Profiles'Access,
      Slugs           => Sql.Batch_Articles_By_Slug'Access,
      Ids             => Sql.Batch_Articles_By_Id'Access,
      Threads         => Sql.Batch_Comments'Access,
      Global          => Sql.Batch_Global'Access,
      Tag_Pages       => Sql.Batch_Tagged'Access,
      Author_Pages    => Sql.Batch_Authored'Access,
      Favoriter_Pages => Sql.Batch_Favorited'Access,
      Feeds           => Sql.Batch_Feed'Access];

   ------------
   -- Row_At --
   ------------

   function Row_At (Rows : Row_Array; Key : Natural) return Natural is
     (if Key in Batch_Index then Rows (Key) else 0);

   --  Batch article columns.
   Id_Column          : constant := 2;
   Author_Column      : constant := 3;
   Slug_Column        : constant := 4;
   Title_Column       : constant := 5;
   Description_Column : constant := 6;
   Created_Column     : constant := 7;
   Updated_Column     : constant := 8;
   Body_Column        : constant := 9;

   ------------
   -- Shaped --
   ------------

   function Shaped (Batch : Job_List) return Boolean is (Batch'First = 1 and then Batch'Last <= Max_Batch);

   ---------
   -- Log --
   ---------

   procedure Log (Message : String) is begin
      Effects.Log (Message);
   end Log;

   ---------------------------------------------------------------------------------------------------------------
   --  handing jobs on

   ------------
   -- Answer --
   ------------

   procedure Answer (Batch : in out Job_List; Index : Positive)
      with Pre  => Index in Batch'Range,
           Post => Batch (Index) = null
   is begin
      if Batch (Index) /= null then
         Effects.Complete (Batch (Index));
      end if;
   end Answer;

   ------------------
   -- Answer_Error --
   ------------------

   procedure Answer_Error (Batch : in out Job_List; Index : Positive; Status : Status_Code)
      with Pre  => Index in Batch'Range,
           Post => Batch (Index) = null
   is begin
      if Batch (Index) /= null then
         Fail (Batch (Index).all, Status);
         Effects.Complete (Batch (Index));
      end if;
   end Answer_Error;

   -----------------
   -- Answer_Rest --
   -----------------

   procedure Answer_Rest (Batch : in out Job_List; Status : Status_Code)
      with Post => (for all Index in Batch'Range => Batch (Index) = null)
   is begin
      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Fail (Batch (Index).all, Status);
            Effects.Complete (Batch (Index));
         end if;
         pragma Loop_Invariant (for all Earlier in Batch'First .. Index => Batch (Earlier) = null);
      end loop;
   end Answer_Rest;

   ---------------------------------------------------------------------------------------------------------------
   --  results

   ----------
   -- Item --
   ----------

   --  A field of a result; NULL outside any result.
   function Item (Lane : Connection;
                  Results : Result_Table;
                  Result : Result_Slot;
                  Row, Column : Positive)
                  return Field
      is (if Result = 0
          then Field_At (Lane, Results (1), 1, Positive'Last)
          else Field_At (Lane, Results (Result), Row, Column));

   -----------
   -- Value --
   -----------

   function Value (Lane : Connection;
                   Results : Result_Table;
                   Result : Result_Slot;
                   Row, Column : Positive)
                   return Long_Long_Integer
      is (Integer_Value (Lane, Item (Lane, Results, Result, Row, Column)));

   ---------------
   -- Row_Count --
   ---------------

   function Row_Count (Results : Result_Table; Result : Result_Slot) return Natural is
     (if Result = 0 then 0 else Results (Result).Row_Count);

   ---------------
   -- Succeeded --
   ---------------

   function Succeeded (Results : Result_Table; First, Last : Natural) return Boolean is
     (for all Index in First .. Last => Index not in Results'Range or else Results (Index).Succeeded);

   ---------------
   -- Page_Size --
   ---------------

   --  The page a list job reads.
   function Page_Size (W : Workspace; Request : Ask) return Natural is
     (case Request.Kind is
         when Global_Ask => (if Request.Key = 0 then 0 else Row_Groups.Size (W.Global_Rows, Request.Key)),
         when List_Ask   => (if Request.Page_Key = 0
                             then 0
                             else Row_Groups.Size (W.List_Rows (Request.Filter), Request.Page_Key)),
         when Feed_Ask   => (if Request.Feed_Key = 0 then 0 else Row_Groups.Size (W.Feed_Rows, Request.Feed_Key)),
         when others     => 0);

   --------------
   -- Page_Row --
   --------------

   function Page_Row (W : Workspace; Request : Ask; Position : Positive) return Positive is
     (case Request.Kind is
         when Global_Ask => Row_Groups.Row (W.Global_Rows, Positive'Max (Request.Key, 1), Position),
         when List_Ask   => Row_Groups.Row (W.List_Rows (Request.Filter), Positive'Max (Request.Page_Key, 1),Position),
         when Feed_Ask   => Row_Groups.Row (W.Feed_Rows, Positive'Max (Request.Feed_Key, 1), Position),
         when others     => 1);

   -----------------
   -- Page_Result --
   -----------------

   function Page_Result (W : Workspace; Request : Ask) return Result_Slot is
     (case Request.Kind is
         when Global_Ask => W.Slot (Global),
         when List_Ask   => W.Slot (List_Statement_Of (Request.Filter)),
         when Feed_Ask   => W.Slot (Feeds),
         when others     => 0);

   ---------------------------------------------------------------------------------------------------------------
   --  planning

   -----------------
   -- Start_Batch --
   -----------------

   --  Empty sets and tables for a batch of Room jobs, and the batch's clock.
   procedure Start_Batch (W : in out Workspace; Room : Natural)
      with Pre => Room <= Max_Batch
   is begin
      Effects.Read_Clock (W.Now);
      W.Asks           := [others => (Kind => No_Ask)];
      W.Want_Tags      := False;
      W.Slot           := [others => 0];
      W.Slot_B         := [others => 0];
      W.Result_Count   := 0;
      W.Profiles_Found := [others => 0];
      W.Slugs_Found    := [others => 0];
      W.Ids_Found      := [others => 0];
      W.Global_Count   := [others => 0];
      W.Feed_Counts    := [others => 0];
      W.List_Counts    := [others => [others => 0]];
      W.Thread_Exists  := [others => False];
      Numbers.Reset (W.User_Keys, Room);
      Text_Sets.Reset (W.Login_Keys, Room);
      Text_Sets.Reset (W.Profile_Keys, Room);
      Text_Sets.Reset (W.Slug_Keys, Room);
      Numbers.Reset (W.Id_Keys, Room);
      Text_Sets.Reset (W.Thread_Keys, Room);
      Pairs.Reset (W.Thread_Views, Room);
      Triples.Reset (W.Global_Pages, Room);
      for Filter in Filtered loop
         Text_Sets.Reset (W.List_Keys (Filter), Room);
         Triples.Reset (W.List_Pages (Filter), Room);
      end loop;
      Numbers.Reset (W.Feed_Viewers, Room);
      Triples.Reset (W.Feed_Pages, Room);
   end Start_Batch;

   --------------
   -- Add_Text --
   --------------

   procedure Add_Text (Set : in out Text_Sets.Set; Text : access constant String; Position : out Natural) is begin
      Position := 0;
      if Text /= null then
         Text_Sets.Add (Set, Text.all, Position);
      end if;
   end Add_Text;

   --------------
   -- Plan_Job --
   --------------

   --  The phase A keys of one job, and its Ask.
   procedure Plan_Job (W : in out Workspace; Batch : Job_List; Index : Positive)
      with Pre => Shaped (Batch) and then Index in Batch'Range and then Batch (Index) /= null
   is
      Viewer   : constant Long_Long_Integer := Long_Long_Integer (Batch (Index).Viewer);
      Key      : Natural;
      Page_Key : Natural := 0;
   begin
      if Batch (Index).Stage = Reading_Back then
         if Batch (Index).Kind in Article_Endpoint then
            Numbers.Add (W.Id_Keys, Long_Long_Integer (Batch (Index).Changed), Key);
            W.Asks (Index) := (Id_Ask, Key);
         end if;
         return;
      end if;

      case Batch (Index).Kind is
         when List_Tags =>
            W.Want_Tags    := True;
            W.Asks (Index) := (Kind => Tags_Ask);
         when Current_User =>
            Numbers.Add (W.User_Keys, Viewer, Key);
            W.Asks (Index) := (User_Ask, Key);
         when Login =>
            Add_Text (W.Login_Keys, Batch (Index).Account.Email, Key);
            W.Asks (Index) := (Login_Ask, Key);
         when Get_Profile =>
            Add_Text (W.Profile_Keys, Batch (Index).Username, Key);
            W.Asks (Index) := (Profile_Ask, Key);
         when Get_Article =>
            Add_Text (W.Slug_Keys, Batch (Index).Slug, Key);
            W.Asks (Index) := (Slug_Ask, Key);
         when List_Comments =>
            Add_Text (W.Thread_Keys, Batch (Index).Slug, Key);
            W.Asks (Index) := (Comments_Ask, Key);
            if Viewer /= 0 and then Key /= 0 then
               Pairs.Include (W.Thread_Views, (Viewer, Long_Long_Integer (Key)));
            end if;
         when List_Articles =>
            declare
               Limit  : constant Long_Long_Integer := Long_Long_Integer (Batch (Index).Page.Limit);
               Offset : constant Long_Long_Integer := Long_Long_Integer (Batch (Index).Page.Offset);
            begin
               case Batch (Index).Filter.Kind is
                  when No_Filter =>
                     Triples.Add (W.Global_Pages, (0, Limit, Offset), Key);
                     W.Asks (Index) := (Global_Ask, Key);
                  when Filtered =>
                     declare
                        Filter : constant Filtered := Batch (Index).Filter.Kind;
                     begin
                        Add_Text (W.List_Keys (Filter), Batch (Index).Filter.Value, Key);
                        if Key /= 0 then
                           Triples.Add (W.List_Pages (Filter), (Long_Long_Integer (Key), Limit, Offset), Page_Key);
                        end if;
                        W.Asks (Index) := (List_Ask, Filter, Key, Page_Key);
                     end;
               end case;
            end;
         when Feed =>
            Numbers.Add (W.Feed_Viewers, Viewer, Key);
            Triples.Add (This     => W.Feed_Pages,
                         Item     => (Viewer,
                                      Long_Long_Integer (Batch (Index).Page.Limit),
                                      Long_Long_Integer (Batch (Index).Page.Offset)),
                         Position => Page_Key);
            W.Asks (Index) := (Feed_Ask, Key, Page_Key);
         when others =>
            null;   --  not a read: left unplanned
      end case;
   end Plan_Job;

   ----------
   -- Plan --
   ----------

   procedure Plan (W : in out Workspace; Batch : in out Job_List)
      with Pre => Shaped (Batch)
   is
      Abandoned : Boolean;
   begin
      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Effects.Check_Abandoned (Batch (Index), Abandoned);
            if Abandoned then
               Answer (Batch, Index);   --  the client hung up: nothing to read
            else
               Plan_Job (W, Batch, Index);
               if not Planned (W.Asks (Index)) then
                  Log ("planner: a job could not be planned");
                  Answer_Error (Batch, Index, Internal_Server_Error);
               end if;
            end if;
         end if;
      end loop;
   end Plan;

   ---------------------------------------------------------------------------------------------------------------
   --  arrays

   -----------------
   -- Add_Numbers --
   -----------------

   procedure Add_Numbers (Lane : in out Connection; Keys : Numbers.Set) is begin
      Begin_Array (Lane, Int8_Oid, Numbers.Length (Keys));
      for Position in 1 .. Numbers.Length (Keys) loop
         Add_Element (Lane, Numbers.Element (Keys, Position));
      end loop;
      End_Array (Lane);
   end Add_Numbers;

   ---------------
   -- Add_Texts --
   ---------------

   procedure Add_Texts (Lane : in out Connection; Keys : Text_Sets.Set) is begin
      Begin_Array (Lane, Text_Oid, Text_Sets.Length (Keys));
      for Position in 1 .. Text_Sets.Length (Keys) loop
         Add_Element (Lane, Text_Sets.Element (Keys, Position));
      end loop;
      End_Array (Lane);
   end Add_Texts;

   type Triple_Part is (Key_Part, Limit_Part, Offset_Part);

   -----------------
   -- Add_Triples --
   -----------------

   procedure Add_Triples (Lane : in out Connection; Keys : Triples.Set; Part : Triple_Part) is begin
      Begin_Array (Lane, Int8_Oid, Triples.Length (Keys));
      for Position in 1 .. Triples.Length (Keys) loop
         declare
            Key : constant Triple := Triples.Element (Keys, Position);
         begin
            Add_Element (This  => Lane,
                         Value => (case Part is
                                      when Key_Part    => Key.Key,
                                      when Limit_Part  => Key.Limit,
                                      when Offset_Part => Key.Offset));
         end;
      end loop;
      End_Array (Lane);
   end Add_Triples;

   --------------------
   -- Add_Pair_Parts --
   --------------------

   procedure Add_Pair_Parts (Lane : in out Connection; Keys : Pairs.Set; Left : Boolean) is begin
      Begin_Array (Lane, Int8_Oid, Pairs.Length (Keys));
      for Position in 1 .. Pairs.Length (Keys) loop
         Add_Element (This  => Lane,
                      Value => (if Left then Pairs.Element (Keys, Position).Left
                                else Pairs.Element (Keys, Position).Right));
      end loop;
      End_Array (Lane);
   end Add_Pair_Parts;

   -------------------
   -- Add_Page_Keys --
   -------------------

   --  The list key (text) of each page of a filter.
   procedure Add_Page_Keys (Lane : in out Connection; Keys : Text_Sets.Set; Pages : Triples.Set) is begin
      Begin_Array (Lane, Text_Oid, Triples.Length (Pages));
      for Position in 1 .. Triples.Length (Pages) loop
         declare
            Key : constant Long_Long_Integer := Triples.Element (Pages, Position).Key;
         begin
            if Key in 1 .. Long_Long_Integer (Text_Sets.Length (Keys)) then
               Add_Element (Lane, Text_Sets.Element (Keys, Positive (Key)));
            else
               Add_Element (Lane, "");
            end if;
         end;
      end loop;
      End_Array (Lane);
   end Add_Page_Keys;

   ---------------------
   -- Add_Feed_Depths --
   ---------------------

   --  Each feed viewer's depth: the most rows any of their pages needs.
   procedure Add_Feed_Depths (Lane : in out Connection; Viewers : Numbers.Set; Pages : Triples.Set) is
      Depth : Count_Array := [others => 1];
      Count : constant Natural := Natural'Min (Numbers.Length (Viewers), Max_Batch);
   begin
      for Position in 1 .. Triples.Length (Pages) loop
         declare
            Page   : constant Triple := Triples.Element (Pages, Position);
            Viewer : constant Natural := Numbers.Find (Viewers, Page.Key);
            Needed : constant Long_Long_Integer :=
              (if Page.Limit in 0 .. 1_000 and then Page.Offset in 0 .. Long_Long_Integer'Last - 1_000
               then Page.Limit + Page.Offset else Long_Long_Integer'Last);
         begin
            if Viewer in Batch_Index then
               Depth (Viewer) := Long_Long_Integer'Max (Depth (Viewer), Needed);
            end if;
         end;
      end loop;

      Begin_Array (Lane, Int8_Oid, Count);
      for Position in 1 .. Count loop
         Add_Element (Lane, Depth (Position));
      end loop;
      End_Array (Lane);
   end Add_Feed_Depths;

   ---------
   -- Run --
   ---------

   --  Queue one phase A statement over the batch's keys; its result goes to the next slot.
   procedure Run (W : in out Workspace; Lane : in out Connection; Statement : Phase_A_Statement)
      with Post => W.Result_Count >= W.Result_Count'Old
   is
      Count : constant Result_Slot := W.Result_Count;
   begin
      if Count = Max_Results then
         return;   --  never: there are fewer statements than results
      end if;

      W.Result_Count     := Count + 1;
      W.Slot (Statement) := W.Result_Count;
      Bind (Lane, Statement_Of (Statement).all);
      case Statement is
         when Tags =>
            null;
         when Users =>
            Add_Numbers (Lane, W.User_Keys);
         when Logins =>
            Add_Texts (Lane, W.Login_Keys);
         when Profiles =>
            Add_Texts (Lane, W.Profile_Keys);
         when Slugs =>
            Add_Texts (Lane, W.Slug_Keys);
         when Ids =>
            Add_Numbers (Lane, W.Id_Keys);
         when Threads =>
            Add_Texts (Lane, W.Thread_Keys);
            Add_Pair_Parts (Lane, W.Thread_Views, Left => True);
            Add_Pair_Parts (Lane, W.Thread_Views, Left => False);
         when Global =>
            Add_Triples (Lane, W.Global_Pages, Limit_Part);
            Add_Triples (Lane, W.Global_Pages, Offset_Part);
         when List_Statement =>
            Add_Texts (Lane, W.List_Keys (Filter_Of (Statement)));
            Add_Page_Keys (Lane, W.List_Keys (Filter_Of (Statement)), W.List_Pages (Filter_Of (Statement)));
            Add_Triples (Lane, W.List_Pages (Filter_Of (Statement)), Limit_Part);
            Add_Triples (Lane, W.List_Pages (Filter_Of (Statement)), Offset_Part);
         when Feeds =>
            Add_Numbers (Lane, W.Feed_Viewers);
            Add_Triples (Lane, W.Feed_Pages, Key_Part);
            Add_Triples (Lane, W.Feed_Pages, Limit_Part);
            Add_Triples (Lane, W.Feed_Pages, Offset_Part);
            Add_Feed_Depths (Lane, W.Feed_Viewers, W.Feed_Pages);
      end case;
      Execute (Lane);
   end Run;

   ---------------------------------------------------------------------------------------------------------------
   --  decoding phase A

   -----------------
   -- Rows_By_Key --
   -----------------

   --  The first row of each key of a lookup statement (k in column 1).
   function Rows_By_Key (Lane : Connection;
                         Results : Result_Table;
                         Result : Result_Slot;
                         Count : Natural)
                         return Row_Array
   is
      Rows : Row_Array := [others => 0];
   begin
      for Row in 1 .. Row_Count (Results, Result) loop
         declare
            Key : constant Long_Long_Integer := Value (Lane, Results, Result, Row, 1);
         begin
            if Key in 1 .. Long_Long_Integer (Natural'Min (Count, Max_Batch)) and then Rows (Positive (Key)) = 0 then
               Rows (Positive (Key)) := Row;
            end if;
         end;
      end loop;
      return Rows;
   end Rows_By_Key;

   -----------------
   -- Decode_List --
   -----------------

   --  A list statement's counts (k <= 0) and pages (k > 0), each page newest first.
   procedure Decode_List (Lane       : Connection;
                          Results    : Result_Table;
                          Result     : Result_Slot;
                          Page_Count : Natural;
                          Counts     : out Count_Array;
                          Pages      : in out Row_Groups.Groups)
   is begin
      Counts := [others => 0];
      Row_Groups.Reset (This        => Pages,
                        Group_Count => Natural'Min (Page_Count, Row_Groups.Max_Rows),
                        Room        => Natural'Min (Row_Count (Results, Result), Row_Groups.Max_Rows));

      for Row in 1 .. Row_Count (Results, Result) loop
         declare
            Key : constant Long_Long_Integer := Value (Lane, Results, Result, Row, 1);
         begin
            if Key <= 0 then
               if Key >= -Long_Long_Integer (Max_Batch) then
                  declare
                     Count_Key : constant Positive := Positive (Long_Long_Integer'Max (-Key, 1));
                  begin
                     if not Is_Null (Item (Lane, Results, Result, Row, 2)) then
                        Counts (Count_Key) := Value (Lane, Results, Result, Row, 2);
                     end if;
                  end;
               end if;
            else
               Row_Groups.Add (Pages, Key, Row, Value (Lane, Results, Result, Row, Id_Column));
            end if;
         end;
      end loop;

      Row_Groups.Close (Pages, By_Key_Descending => True);
   end Decode_List;

   --------------------
   -- Decode_Threads --
   --------------------

   --  Comment threads: k 0 is a thread's existence and its comments, k 1 an author, k 2 a follow.
   procedure Decode_Threads (W : in out Workspace; Lane : Connection) is
      Result : constant Result_Slot := W.Slot (Threads);
   begin
      Row_Groups.Reset (This        => W.Thread_Rows,
                        Group_Count => Natural'Min (Text_Sets.Length (W.Thread_Keys), Row_Groups.Max_Rows),
                        Room        => Natural'Min (Row_Count (W.Results, Result), Row_Groups.Max_Rows));
      Numbers.Reset (W.Thread_Authors, Natural'Min (Row_Count (W.Results, Result), Numbers.Max_Capacity));
      Pairs.Reset (W.Thread_Follows, Natural'Min (Row_Count (W.Results, Result), Pairs.Max_Capacity));

      for Row in 1 .. Row_Count (W.Results, Result) loop
         case Value (Lane, W.Results, Result, Row, 1) is
            when 0 =>
               declare
                  Thread : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, 2);
               begin
                  if Thread in 1 .. Long_Long_Integer (Max_Batch) then
                     W.Thread_Exists (Positive (Thread)) := True;
                     if not Is_Null (Item (Lane, W.Results, Result, Row, 3)) then
                        Row_Groups.Add (W.Thread_Rows, Thread, Row);
                     end if;
                  end if;
               end;
            when 1 =>
               Numbers.Include (W.Thread_Authors, Value (Lane, W.Results, Result, Row, 2), Row);
            when others =>
               Pairs.Include (This => W.Thread_Follows,
                              Item => (Value (Lane, W.Results, Result, Row, 2),
                                       Value (Lane, W.Results, Result, Row, 3)));
         end case;
      end loop;

      Row_Groups.Close (W.Thread_Rows, By_Key_Descending => False);
   end Decode_Threads;

   --------------------
   -- Decode_Phase_A --
   --------------------

   procedure Decode_Phase_A (W : in out Workspace; Lane : Connection) is begin
      W.Profiles_Found := Rows_By_Key (Lane, W.Results, W.Slot (Profiles), Text_Sets.Length (W.Profile_Keys));
      W.Slugs_Found    := Rows_By_Key (Lane, W.Results, W.Slot (Slugs), Text_Sets.Length (W.Slug_Keys));
      W.Ids_Found      := Rows_By_Key (Lane, W.Results, W.Slot (Ids), Numbers.Length (W.Id_Keys));
      Decode_List (Lane, W.Results, W.Slot (Global), Triples.Length (W.Global_Pages), W.Global_Count, W.Global_Rows);
      Decode_List (Lane, W.Results, W.Slot (Feeds), Triples.Length (W.Feed_Pages), W.Feed_Counts, W.Feed_Rows);

      for Filter in Filtered loop
         Decode_List (Lane       => Lane,
                      Results    => W.Results,
                      Result     => W.Slot (List_Statement_Of (Filter)),
                      Page_Count => Triples.Length (W.List_Pages (Filter)),
                      Counts     => W.List_Counts (Filter),
                      Pages      => W.List_Rows (Filter));
      end loop;

      Decode_Threads (W, Lane);
   end Decode_Phase_A;

   ---------------------------------------------------------------------------------------------------------------
   --  early answers: tag lists, current users, logins

   ------------------
   -- Answer_Early --
   ------------------

   procedure Answer_Early (W : Workspace; Lane : Connection; Batch : in out Job_List)
      with Pre => Shaped (Batch)
   is
      Users_Found  : constant Row_Array :=
        Rows_By_Key (Lane, W.Results, W.Slot (Users), Numbers.Length (W.User_Keys));
      Logins_Found : constant Row_Array :=
        Rows_By_Key (Lane, W.Results, W.Slot (Logins), Text_Sets.Length (W.Login_Keys));
      Now          : constant Unix_Seconds := Unix_Seconds'Max (0, Unix_Seconds'Min (W.Now, 10 ** 15));
      Tag_List     : Buffer;
   begin
      if W.Want_Tags then
         Append (Tag_List, "{""tags"":[");
         for Row in 1 .. Row_Count (W.Results, W.Slot (Tags)) loop
            pragma Loop_Invariant (Valid (Tag_List));
            if Row > 1 then
               Append (Tag_List, ',');
            end if;
            Append_Json_String (Tag_List, Text (Lane, Item (Lane, W.Results, W.Slot (Tags), Row, 2)));
         end loop;
         Append (Tag_List, "]}");
      end if;

      for Index in Batch'Range loop
         pragma Loop_Invariant (Valid (Tag_List));
         if Batch (Index) /= null then
            case W.Asks (Index).Kind is
               when Tags_Ask =>
                  Restart (Batch (Index).Response);
                  Append (Batch (Index).Response, Content (Tag_List));
                  Answer (Batch, Index);
               when User_Ask =>
                  declare
                     Row : constant Natural := Row_At (Users_Found, W.Asks (Index).Key);
                  begin
                     if Row = 0 or else W.Slot (Users) = 0 or else Batch (Index).Kind not in Account_Endpoint then
                        Answer_Error (Batch, Index, Unauthorized);   --  the token's user no longer exists
                     else
                        Restart (Batch (Index).Response);
                        Render.User (Into  => Batch (Index).Response,
                                     From  => Lane,
                                     Rows  => W.Results (W.Slot (Users)),
                                     Token => (if Batch (Index).Account.Token /= null
                                               then Batch (Index).Account.Token.all else ""),
                                     Row   => Row,
                                     First => 2);
                        Answer (Batch, Index);
                     end if;
                  end;
               when Login_Ask =>
                  declare
                     Row  : constant Natural := Row_At (Logins_Found, W.Asks (Index).Key);
                     User : constant Long_Long_Integer :=
                       Value (Lane, W.Results, W.Slot (Logins), Positive'Max (Row, 1), 2);
                  begin
                     if Row = 0 or else W.Slot (Logins) = 0 then
                        Answer_Error (Batch, Index, Unauthorized);
                     elsif User < 1 or else Batch (Index).Kind not in Account_Endpoint then
                        Answer_Error (Batch, Index, Internal_Server_Error);
                     else
                        Restart (Batch (Index).Response);
                        Render.User (Into  => Batch (Index).Response,
                                     From  => Lane,
                                     Rows  => W.Results (W.Slot (Logins)),
                                     Token => Jwt.Sign (Known_User (User), Now),
                                     Row   => Row,
                                     First => 2);
                        Free (Batch (Index).Account.Password_Hash);
                        Batch (Index).Account.Password_Hash :=
                          new String'(Text (Lane, Item (Lane, W.Results, W.Slot (Logins), Row, 7)));
                        Batch (Index).Stage := Verifying;   --  the response is ready; bcrypt decides if it is sent
                        Effects.Submit (Batch (Index));
                     end if;
                  end;
               when others =>
                  null;
            end case;
         end if;
      end loop;

      pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "releases memory before scope end");
      pragma Warnings (GNATprove, Off, """Tag_List"" is set by ""Free"" but not used after the call",
                       Reason => "releases memory before scope end");
      Free (Tag_List);
      pragma Warnings (GNATprove, On, """Tag_List"" is set by ""Free"" but not used after the call");
      pragma Warnings (GNATprove, On, "statement has no effect");
   end Answer_Early;

   ---------------------------------------------------------------------------------------------------------------
   --  phase B keys

   -----------------
   -- Add_Article --
   -----------------

   --  The article's details, and whether the viewer favorited it.
   procedure Add_Article (W : in out Workspace; Id, Author : Long_Long_Integer; Viewer : User_Id) is begin
      Authored.Include (W.Articles, Id, Author);
      if Viewer /= Anonymous then
         Pairs.Include (W.Favorite_Asks, (Long_Long_Integer (Viewer), Id));
      end if;
   end Add_Article;

   ----------------
   -- Add_Follow --
   ----------------

   --  Whether the viewer follows the author (a feed's authors are followed by definition).
   procedure Add_Follow (W : in out Workspace; Viewer : User_Id; Author : Long_Long_Integer) is begin
      if Viewer /= Anonymous then
         Pairs.Include (W.Follow_Asks, (Long_Long_Integer (Viewer), Author));
      end if;
   end Add_Follow;

   --------------
   -- Add_Page --
   --------------

   --  Every article on a list job's page.
   procedure Add_Page (W : in out Workspace; Lane : Connection; Request : Ask; Viewer : User_Id)
      with Pre => Request.Kind in Global_Ask | List_Ask | Feed_Ask
   is
      Result  : constant Result_Slot := Page_Result (W, Request);
      Is_Feed : constant Boolean := Request.Kind = Feed_Ask;
   begin
      for Position in 1 .. Page_Size (W, Request) loop
         declare
            Row    : constant Positive := Page_Row (W, Request, Position);
            Id     : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, Id_Column);
            Author : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, Author_Column);
         begin
            if not Is_Feed then
               Article_Index.Include (W.Full_Rows, Id, (Result, Row));
            end if;
            Add_Article (W, Id, Author, Viewer);
            if not Is_Feed then
               Add_Follow (W, Viewer, Author);
            end if;
         end;
      end loop;
   end Add_Page;

   ------------------
   -- Add_Job_Keys --
   ------------------

   --  The phase B keys of one job.
   procedure Add_Job_Keys (W : in out Workspace; Lane : Connection; Batch : Job_List; Index : Positive)
      with Pre => Shaped (Batch) and then Index in Batch'Range and then Batch (Index) /= null
   is
      Request : constant Ask := W.Asks (Index);
      Viewer  : constant User_Id := Batch (Index).Viewer;
   begin
      case Request.Kind is
         when Slug_Ask | Id_Ask =>
            declare
               Statement : constant Phase_A_Statement := (if Request.Kind = Slug_Ask then Slugs else Ids);
               Row       : constant Natural :=
                 (if Request.Kind = Slug_Ask then Row_At (W.Slugs_Found, Request.Key)
                  else Row_At (W.Ids_Found, Request.Key));
            begin
               if Row /= 0 then
                  declare
                     Result : constant Result_Slot := W.Slot (Statement);
                     Id     : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, Id_Column);
                     Author : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, Author_Column);
                  begin
                     Article_Index.Include (W.Full_Rows, Id, (Result, Row));
                     Add_Article (W, Id, Author, Viewer);
                     Add_Follow (W, Viewer, Author);
                  end;
               end if;
            end;
         when Global_Ask | List_Ask | Feed_Ask =>
            Add_Page (W, Lane, Request, Viewer);
         when Profile_Ask =>
            if Row_At (W.Profiles_Found, Request.Key) /= 0 then
               Add_Follow (W      => W,
                           Viewer => Viewer,
                           Author => Value (Lane    => Lane,
                                            Results => W.Results,
                                            Result  => W.Slot (Profiles),
                                            Row     => Row_At (W.Profiles_Found, Request.Key),
                                            Column  => 2));
            end if;
         when others =>
            null;
      end case;
   end Add_Job_Keys;

   ----------------------
   -- Add_Missing_Rows --
   ----------------------

   --  Feed articles nothing else in the batch returned the columns of.
   procedure Add_Missing_Rows (W : in out Workspace; Lane : Connection; Index : Batch_Index) is
      Request : constant Ask := W.Asks (Index);
   begin
      for Position in 1 .. Page_Size (W, Request) loop
         declare
            Id : constant Long_Long_Integer :=
              Value (Lane, W.Results, W.Slot (Feeds), Page_Row (W, Request, Position), Id_Column);
         begin
            if not Article_Index.Contains (W.Full_Rows, Id) then
               Numbers.Include (W.Missing_Rows, Id);
            end if;
         end;
      end loop;
   end Add_Missing_Rows;

   ------------------
   -- Plan_Phase_B --
   ------------------

   --  Everything phase B is asked, sized by the rows the jobs' pages hold plus one per lookup.
   procedure Plan_Phase_B (W : in out Workspace; Lane : Connection; Batch : Job_List)
      with Pre => Shaped (Batch)
   is
      Page_Rows : Natural := 0;
   begin
      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Page_Rows := Saturating_Sum (Left  => Page_Rows,
                                         Right => (if W.Asks (Index).Kind in Global_Ask | List_Ask | Feed_Ask
                                                   then Page_Size (W, W.Asks (Index)) else 1),
                                         Limit => Numbers.Max_Capacity);
         end if;
         pragma Loop_Invariant (Page_Rows <= Numbers.Max_Capacity);
      end loop;

      Authored.Reset (W.Articles, Page_Rows);
      Pairs.Reset (W.Favorite_Asks, Page_Rows);
      Pairs.Reset (W.Follow_Asks, Page_Rows);
      Article_Index.Reset (W.Full_Rows, Page_Rows);
      Numbers.Reset (W.Missing_Rows, Page_Rows);

      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Add_Job_Keys (W, Lane, Batch, Index);
         end if;
      end loop;

      for Index in Batch'Range loop
         if Batch (Index) /= null and then W.Asks (Index).Kind = Feed_Ask then
            Add_Missing_Rows (W, Lane, Index);
         end if;
      end loop;
   end Plan_Phase_B;

   -------------------
   -- Add_By_Viewer --
   -------------------

   --  Sorted pairs as four arrays: distinct viewers, every target, each viewer's first and last target.
   procedure Add_By_Viewer (Lane : in out Connection; Keys : Pairs.Set) is
      Count   : constant Natural := Pairs.Length (Keys);
      Sorted  : Pair_Array_Access := new Pair_Array'(1 .. Count => (0, 0));
      Viewers : Natural := 0;

      -------------------
      -- Starts_Viewer --
      -------------------

      function Starts_Viewer (Index : Positive) return Boolean is
        (Index = Sorted'First or else Sorted (Index).Left /= Sorted (Index - 1).Left)
      with Pre => Sorted /= null and then Index in Sorted'Range;

      -----------------
      -- Ends_Viewer --
      -----------------

      function Ends_Viewer (Index : Positive) return Boolean is
        (Index = Sorted'Last or else Sorted (Index).Left /= Sorted (Index + 1).Left)
      with Pre => Sorted /= null and then Index in Sorted'Range;
   begin
      for Index in 1 .. Count loop
         Sorted (Index) := Pairs.Element (Keys, Index);
      end loop;
      Sort (Sorted.all);

      for Index in 1 .. Count loop
         pragma Loop_Invariant (Viewers < Index);
         if Starts_Viewer (Index) then
            Viewers := Viewers + 1;
         end if;
      end loop;

      Begin_Array (Lane, Int8_Oid, Viewers);
      for Index in 1 .. Count loop
         if Starts_Viewer (Index) then
            Add_Element (Lane, Sorted (Index).Left);
         end if;
      end loop;
      End_Array (Lane);

      Begin_Array (Lane, Int8_Oid, Count);
      for Index in 1 .. Count loop
         Add_Element (Lane, Sorted (Index).Right);
      end loop;
      End_Array (Lane);

      Begin_Array (Lane, Int8_Oid, Viewers);   --  first positions
      for Index in 1 .. Count loop
         if Starts_Viewer (Index) then
            Add_Element (Lane, Long_Long_Integer (Index));
         end if;
      end loop;
      End_Array (Lane);

      Begin_Array (Lane, Int8_Oid, Viewers);   --  last positions
      for Index in 1 .. Count loop
         if Ends_Viewer (Index) then
            Add_Element (Lane, Long_Long_Integer (Index));
         end if;
      end loop;
      End_Array (Lane);

      Free (Sorted);
   end Add_By_Viewer;

   -----------------
   -- Add_Details --
   -----------------

   procedure Add_Details (Lane : in out Connection; Articles : Authored.Set) is
      Count  : constant Natural := Authored.Length (Articles);
      Sorted : Pair_Array_Access := new Pair_Array'(1 .. Count => (0, 0));
   begin
      for Index in 1 .. Count loop
         Sorted (Index) := (Authored.Element (Articles, Index), Authored.Value (Articles, Index));
      end loop;
      Sort (Sorted.all);

      Begin_Array (Lane, Int8_Oid, Count);
      for Index in 1 .. Count loop
         Add_Element (Lane, Sorted (Index).Left);
      end loop;
      End_Array (Lane);

      Begin_Array (Lane, Int8_Oid, Count);
      for Index in 1 .. Count loop
         Add_Element (Lane, Sorted (Index).Right);
      end loop;
      End_Array (Lane);

      Free (Sorted);
   end Add_Details;

   ---------------
   -- Next_Slot --
   ---------------

   --  Queue a phase B statement (when there is room for its result; there always is).
   procedure Next_Slot (W : in out Workspace; Statement : Phase_B_Statement; Room : out Boolean)
      with Post => (if Room then W.Result_Count in 1 .. Max_Results and then W.Slot_B (Statement) = W.Result_Count)
   is begin
      Room := W.Result_Count < Max_Results;
      if Room then
         W.Result_Count       := W.Result_Count + 1;
         W.Slot_B (Statement) := W.Result_Count;
      end if;
   end Next_Slot;

   ----------
   -- Read --
   ----------

   --  Read the results First .. Final (none when First > Final); Failed when the connection failed.
   procedure Read (W            : in out Workspace;
                   Lane         : in out Connection;
                   First, Final : Natural;
                   Keep_Earlier : Boolean;
                   Failed       : in out Boolean)
   is
      Received : Boolean;
   begin
      if First in W.Results'Range and then Final <= W.Results'Last then
         Try_Read_Results (Lane, W.Results (First .. Final), Received, Keep_Earlier);
      else
         Try_Read_Results (Lane, W.Results (1 .. 0), Received, Keep_Earlier);
      end if;

      if not Received then
         Log ("postgres (reads): " & Last_Failure (Lane));
         Failed := True;
      end if;
   end Read;

   -----------------
   -- Run_Phase_B --
   -----------------

   --  Send phase B and read it back. Unless it all went through, every job left gets a 500 (and Failed is set
   --  when the connection failed).
   procedure Run_Phase_B (W      : in out Workspace;
                          Lane   : in out Connection;
                          Batch  : in out Job_List;
                          Failed : in out Boolean;
                          Done   : out Boolean)
   is
      First : constant Natural := W.Result_Count + 1;
      Room  : Boolean;
      Sent  : Boolean;
   begin
      Done := False;

      if Authored.Length (W.Articles) > 0 then
         Next_Slot (W, Details, Room);
         if Room then
            Bind (Lane, Sql.Batch_Article_Details);
            Add_Details (Lane, W.Articles);
            Execute (Lane);
         end if;
      end if;

      if Pairs.Length (W.Favorite_Asks) > 0 or else Pairs.Length (W.Follow_Asks) > 0 then
         Next_Slot (W, Flags, Room);
         if Room then
            Bind (Lane, Sql.Batch_Flags);
            Add_By_Viewer (Lane, W.Favorite_Asks);
            Add_By_Viewer (Lane, W.Follow_Asks);
            Execute (Lane);
         end if;
      end if;

      if Numbers.Length (W.Missing_Rows) > 0 then
         Next_Slot (W, Article_Rows, Room);
         if Room then
            Bind (Lane, Sql.Batch_Article_Rows);
            Add_Numbers (Lane, W.Missing_Rows);
            Execute (Lane);
         end if;
      end if;

      if W.Result_Count >= First then
         Sync (Lane);
         Try_Flush (Lane, Sent);

         if not Sent then
            Log ("postgres (reads): " & Last_Failure (Lane));
            Failed := True;
            Answer_Rest (Batch, Internal_Server_Error);
            return;
         end if;

         Read (W, Lane, First, W.Result_Count, True, Failed);
         if Failed then
            Answer_Rest (Batch, Internal_Server_Error);
            return;
         end if;

         if not Succeeded (W.Results, First, W.Result_Count) then
            Log ("planner: phase B statement failed");
            Answer_Rest (Batch, Internal_Server_Error);
            return;
         end if;
      end if;

      Done := True;
   end Run_Phase_B;

   --------------------
   -- Decode_Phase_B --
   --------------------

   procedure Decode_Phase_B (W : in out Workspace; Lane : Connection) is
      Tags_Result    : constant Result_Slot := W.Slot (Tags);
      Details_Result : constant Result_Slot := W.Slot_B (Details);
      Flags_Result   : constant Result_Slot := W.Slot_B (Flags);
      Rows_Result    : constant Result_Slot := W.Slot_B (Article_Rows);
   begin
      Numbers.Reset (W.Tag_Rank, Natural'Min (Row_Count (W.Results, Tags_Result), Numbers.Max_Capacity));
      for Row in 1 .. Row_Count (W.Results, Tags_Result) loop
         Numbers.Include (W.Tag_Rank, Value (Lane, W.Results, Tags_Result, Row, 1), Row);
      end loop;

      Numbers.Reset (W.Detail_Rows, Natural'Min (Row_Count (W.Results, Details_Result), Numbers.Max_Capacity));
      for Row in 1 .. Row_Count (W.Results, Details_Result) loop
         Numbers.Include (W.Detail_Rows, Value (Lane, W.Results, Details_Result, Row, 1), Row);
      end loop;

      Pairs.Reset (W.Favorited_Set, Natural'Min (Row_Count (W.Results, Flags_Result), Pairs.Max_Capacity));
      Pairs.Reset (W.Following_Set, Natural'Min (Row_Count (W.Results, Flags_Result), Pairs.Max_Capacity));
      for Row in 1 .. Row_Count (W.Results, Flags_Result) loop
         declare
            Found : constant Pair :=
              (Value (Lane, W.Results, Flags_Result, Row, 2), Value (Lane, W.Results, Flags_Result, Row, 3));
         begin
            if Value (Lane, W.Results, Flags_Result, Row, 1) = 0 then
               Pairs.Include (W.Favorited_Set, Found);
            else
               Pairs.Include (W.Following_Set, Found);
            end if;
         end;
      end loop;

      for Row in 1 .. Row_Count (W.Results, Rows_Result) loop
         Article_Index.Include (This  => W.Full_Rows,
                                Item  => Value (Lane, W.Results, Rows_Result, Row, Id_Column),
                                Value => (Rows_Result, Row));
      end loop;
   end Decode_Phase_B;

   ------------------
   -- Is_Favorited --
   ------------------

   function Is_Favorited (W : Workspace; Viewer : User_Id; Article : Long_Long_Integer) return Boolean is
     (Viewer /= Anonymous and then Pairs.Contains (W.Favorited_Set, (Long_Long_Integer (Viewer), Article)));

   ---------------
   -- Following --
   ---------------

   function Following (W : Workspace; Viewer : User_Id; Author : Long_Long_Integer) return Boolean is
     (Viewer /= Anonymous and then Pairs.Contains (W.Following_Set, (Long_Long_Integer (Viewer), Author)));

   ---------------------------------------------------------------------------------------------------------------
   --  rendering

   -------------------------
   -- Append_Text_Or_Null --
   -------------------------

   procedure Append_Text_Or_Null (Into : in out Buffer; Lane : Connection; Data : Field)
      with Pre => Valid (Into), Post => Valid (Into) and then Into.Length >= Into.Length'Old
   is begin
      if Is_Null (Data) then
         Append (Into, "null");
      else
         Append_Json_String (Into, Text (Lane, Data));
      end if;
   end Append_Text_Or_Null;

   --------------------
   -- Append_Boolean --
   --------------------

   procedure Append_Boolean (Into : in out Buffer; Value : Boolean)
      with Pre => Valid (Into), Post => Valid (Into) and then Into.Length >= Into.Length'Old
   is begin
      Append (Into, (if Value then "true" else "false"));
   end Append_Boolean;

   -----------------
   -- Append_Tags --
   -----------------

   --  The tag names of an article, in name order (their rank in Tags).
   procedure Append_Tags (Into : in out Buffer; W : Workspace; Lane : Connection; Tag_Ids : Field; Count : Natural)
      with Pre => Valid (Into), Post => Valid (Into) and then Into.Length >= Into.Length'Old
   is
      Ranks : Rank_Array (1 .. Count);
      First : Boolean := True;
   begin
      for Index in Ranks'Range loop
         declare
            Rank : constant Natural := Numbers.Find (W.Tag_Rank, Integer_Value (Lane, Element (Lane, Tag_Ids, Index)));
         begin
            Ranks (Index) := (if Rank = 0 then 0 else Numbers.Value (W.Tag_Rank, Rank));
         end;
      end loop;

      for Next in 2 .. Ranks'Last loop   --  insertion sort: an article has few tags
         declare
            Moving : constant Natural := Ranks (Next);
            Hole   : Positive := Next;
         begin
            while Hole > 1 and then Ranks (Hole - 1) > Moving loop
               pragma Loop_Invariant (Hole in 2 .. Next);
               pragma Loop_Variant (Decreases => Hole);
               Ranks (Hole) := Ranks (Hole - 1);
               Hole         := Hole - 1;
            end loop;
            Ranks (Hole) := Moving;
         end;
      end loop;

      for Rank of Ranks loop
         pragma Loop_Invariant (Valid (Into) and then Into.Length >= Into.Length'Loop_Entry);
         if Rank /= 0 then
            if not First then
               Append (Into, ',');
            end if;
            First := False;
            Append_Json_String (Into, Text (Lane, Item (Lane, W.Results, W.Slot (Tags), Rank, 2)));
         end if;
      end loop;
   end Append_Tags;

   --------------------
   -- Append_Article --
   --------------------

   --  One Article object; Written is False (and nothing written) when the article vanished between the phases.
   procedure Append_Article (Into      : in out Buffer;
                             W         : Workspace;
                             Lane      : Connection;
                             Source    : Article_Row;
                             With_Body : Boolean;
                             Viewer    : User_Id;
                             Followed  : Boolean;
                             Written   : out Boolean)
      with Pre => Valid (Into), Post => Valid (Into) and then Into.Length >= Into.Length'Old
   is
      Row_Of  : constant Positive := Positive'Max (Source.Row, 1);
      Id      : constant Long_Long_Integer := Value (Lane, W.Results, Source.Result, Row_Of, Id_Column);
      Author  : constant Long_Long_Integer := Value (Lane, W.Results, Source.Result, Row_Of, Author_Column);
      Columns : Article_Row := Source;
      Detail  : constant Natural := Numbers.Find (W.Detail_Rows, Id);

      --  Author rows sit in Detail_Rows under the negated user id.
      Writer  : constant Natural := (if Author > 0 then Numbers.Find (W.Detail_Rows, -Author) else 0);
   begin
      Written := False;
      if Source.Result = 0 or else Source.Row = 0 then
         return;
      end if;

      if Is_Null (Item (Lane, W.Results, Source.Result, Row_Of, Slug_Column)) then
         declare
            Full : constant Natural := Article_Index.Find (W.Full_Rows, Id);
         begin
            if Full = 0 then
               return;
            end if;
            Columns := Article_Index.Value (W.Full_Rows, Full);
         end;
      end if;

      if Detail = 0 or else Writer = 0 or else W.Slot_B (Details) = 0 or else Columns.Row = 0 then
         return;
      end if;

      declare
         Row        : constant Natural := Numbers.Value (W.Detail_Rows, Detail);
         Author_Row : constant Natural := Numbers.Value (W.Detail_Rows, Writer);
         Source_B   : constant Result_Slot := W.Slot_B (Details);

         ------------
         -- Column --
         ------------

         function Column (Index : Positive) return Field is
           (Item (Lane, W.Results, Columns.Result, Columns.Row, Index))
         with Pre => Columns.Row /= 0;

         -------------------
         -- Detail_Column --
         -------------------

         function Detail_Column (Index : Positive) return Field is
           (Item (Lane, W.Results, Source_B, Positive'Max (Row, 1), Index));

         -------------------
         -- Writer_Column --
         -------------------

         function Writer_Column (Index : Positive) return Field is
           (Item (Lane, W.Results, Source_B, Positive'Max (Author_Row, 1), Index));

         Tag_Ids : constant Field := Detail_Column (2);
      begin
         if Row = 0 or else Author_Row = 0 then
            return;
         end if;

         Append (Into, "{""slug"":");
         Append_Json_String (Into, Text (Lane, Column (Slug_Column)));
         Append (Into, ",""title"":");
         Append_Json_String (Into, Text (Lane, Column (Title_Column)));
         Append (Into, ",""description"":");
         Append_Json_String (Into, Text (Lane, Column (Description_Column)));
         if With_Body then
            Append (Into, ",""body"":");
            Append_Json_String (Into, Text (Lane, Column (Body_Column)));
         end if;
         Append (Into, ",""tagList"":[");
         Append_Tags (Into, W, Lane, Tag_Ids, Element_Count (Lane, Tag_Ids));
         Append (Into, "],""createdAt"":");
         Append_Timestamp (Into, Timestamp_Value (Lane, Column (Created_Column)));
         Append (Into, ",""updatedAt"":");
         Append_Timestamp (Into, Timestamp_Value (Lane, Column (Updated_Column)));
         Append (Into, ",""favorited"":");
         Append_Boolean (Into, Is_Favorited (W, Viewer, Id));
         Append (Into, ",""favoritesCount"":");
         Append_Integer (Into, Integer_Value (Lane, Detail_Column (3)));
         Append (Into, ",""author"":{""username"":");
         Append_Json_String (Into, Text (Lane, Writer_Column (4)));
         Append (Into, ",""bio"":");
         Append_Text_Or_Null (Into, Lane, Writer_Column (5));
         Append (Into, ",""image"":");
         Append_Text_Or_Null (Into, Lane, Writer_Column (6));
         Append (Into, ",""following"":");
         Append_Boolean (Into, Followed or else Following (W, Viewer, Author));
         Append (Into, "}}");
         Written := True;
      end;
   end Append_Article;

   ----------------
   -- Write_List --
   ----------------

   --  {"articles": [...], "articlesCount": n} for a list job's page.
   procedure Write_List (Into    : in out Buffer;
                         W       : Workspace;
                         Lane    : Connection;
                         Request : Ask;
                         Viewer  : User_Id;
                         Count   : Long_Long_Integer)
   with Post => Valid (Into)
   is
      Result  : constant Result_Slot := Page_Result (W, Request);
      First   : Boolean := True;
      Mark    : Natural;
      Written : Boolean;
   begin
      Restart (Into);
      Append (Into, "{""articles"":[");
      for Position in 1 .. Page_Size (W, Request) loop
         pragma Loop_Invariant (Valid (Into));
         Mark := Into.Length;
         if not First then
            Append (Into, ',');
         end if;
         Append_Article (Into      => Into,
                         W         => W,
                         Lane      => Lane,
                         Source    => (Result, Page_Row (W, Request, Position)),
                         With_Body => False,
                         Viewer    => Viewer,
                         Followed  => Request.Kind = Feed_Ask,
                         Written   => Written);
         if Written then
            First := False;
         else
            Truncate (Into, Mark);
         end if;
      end loop;

      Append (Into, "],""articlesCount"":");
      Append_Integer (Into, Count);
      Append (Into, "}");
   end Write_List;

   --------------------
   -- Append_Comment --
   --------------------

   --  One comment of a thread, by a known author.
   procedure Append_Comment (Into : in out Buffer;
                             W    : Workspace;
                             Lane : Connection;
                             Row, Author_Row : Positive;
                             Viewer : User_Id)
      with Pre => Valid (Into), Post => Valid (Into)
   is
      Result : constant Result_Slot := W.Slot (Threads);
      Author : constant Long_Long_Integer := Value (Lane, W.Results, Result, Row, 7);
   begin
      Append (Into, "{""id"":");
      Append_Integer (Into, Value (Lane, W.Results, Result, Row, 3));
      Append (Into, ",""createdAt"":");
      Append_Timestamp (Into, Timestamp_Value (Lane, Item (Lane, W.Results, Result, Row, 5)));
      Append (Into, ",""updatedAt"":");
      Append_Timestamp (Into, Timestamp_Value (Lane, Item (Lane, W.Results, Result, Row, 6)));
      Append (Into, ",""body"":");
      Append_Json_String (Into, Text (Lane, Item (Lane, W.Results, Result, Row, 4)));
      Append (Into, ",""author"":{""username"":");
      Append_Json_String (Into, Text (Lane, Item (Lane, W.Results, Result, Author_Row, 4)));
      Append (Into, ",""bio"":");
      Append_Text_Or_Null (Into, Lane, Item (Lane, W.Results, Result, Author_Row, 8));
      Append (Into, ",""image"":");
      Append_Text_Or_Null (Into, Lane, Item (Lane, W.Results, Result, Author_Row, 9));
      Append (Into, ",""following"":");
      Append_Boolean (Into  => Into,
                      Value => Viewer /= Anonymous
                               and then Pairs.Contains (W.Thread_Follows, (Long_Long_Integer (Viewer), Author)));
      Append (Into, "}}");
   end Append_Comment;

   --------------------
   -- Write_Comments --
   --------------------

   --  {"comments": [...]} for a thread.
   procedure Write_Comments
     (Into   : in out Buffer;
      W      : Workspace;
      Lane   : Connection;
      Thread : Positive;
      Viewer : User_Id)
      with Post => Valid (Into)
   is
      Result : constant Result_Slot := W.Slot (Threads);
      First  : Boolean := True;
   begin
      Restart (Into);
      Append (Into, "{""comments"":[");
      for Position in 1 .. Row_Groups.Size (W.Thread_Rows, Thread) loop
         pragma Loop_Invariant (Valid (Into));
         declare
            Row    : constant Positive := Row_Groups.Row (W.Thread_Rows, Thread, Position);
            Author : constant Natural := Numbers.Find (W.Thread_Authors, Value (Lane, W.Results, Result, Row, 7));
         begin
            if Author /= 0 and then Numbers.Value (W.Thread_Authors, Author) /= 0 then
               if not First then
                  Append (Into, ',');
               end if;
               First := False;
               Append_Comment (Into, W, Lane, Row, Numbers.Value (W.Thread_Authors, Author), Viewer);
            end if;
         end;
      end loop;
      Append (Into, "]}");
   end Write_Comments;

   ----------------
   -- Render_Job --
   ----------------

   --  One job's response, from both phases.
   procedure Render_Job (W : Workspace; Lane : Connection; Batch : in out Job_List; Index : Positive)
      with Pre => Shaped (Batch) and then Index in Batch'Range and then Batch (Index) /= null
   is
      Request : constant Ask := W.Asks (Index);
      Viewer  : constant User_Id := Batch (Index).Viewer;
   begin
      case Request.Kind is
         when No_Ask | Early_Ask =>
            Log ("planner: a job was not answered after the first Sync");
            Answer_Error (Batch, Index, Internal_Server_Error);
         when Profile_Ask =>
            declare
               Row : constant Natural := Row_At (W.Profiles_Found, Request.Key);
            begin
               if Row = 0 or else W.Slot (Profiles) = 0 then
                  Answer_Error (Batch, Index, Not_Found);
               else
                  Restart (Batch (Index).Response);
                  Render.Profile (Into      => Batch (Index).Response,
                                  From      => Lane,
                                  Rows      => W.Results (W.Slot (Profiles)),
                                  First     => 3,
                                  Following => Following (W      => W,
                                                          Viewer => Viewer,
                                                          Author => Value (Lane, W.Results, W.Slot (Profiles), Row, 2)),
                                  Row       => Row);
                  Answer (Batch, Index);
               end if;
            end;
         when Slug_Ask | Id_Ask =>
            declare
               Statement : constant Phase_A_Statement := (if Request.Kind = Slug_Ask then Slugs else Ids);
               Row       : constant Natural :=
                 (if Request.Kind = Slug_Ask then Row_At (W.Slugs_Found, Request.Key)
                  else Row_At (W.Ids_Found, Request.Key));
               Written   : Boolean := False;
            begin
               Restart (Batch (Index).Response);
               Append (Batch (Index).Response, "{""article"":");
               if Row /= 0 then
                  Append_Article (Into      => Batch (Index).Response,
                                  W         => W,
                                  Lane      => Lane,
                                  Source    => (W.Slot (Statement), Row),
                                  With_Body => True,
                                  Viewer    => Viewer,
                                  Followed  => False,
                                  Written   => Written);
               end if;
               if Written then
                  Append (Batch (Index).Response, "}");
                  Answer (Batch, Index);
               else
                  Answer_Error (Batch, Index, Not_Found);
               end if;
            end;
         when Comments_Ask =>
            if Request.Key in Batch_Index and then W.Thread_Exists (Request.Key) then
               Write_Comments (Batch (Index).Response, W, Lane, Request.Key, Viewer);
               Answer (Batch, Index);
            else
               Answer_Error (Batch, Index, Not_Found);
            end if;
         when Global_Ask =>
            Write_List (Batch (Index).Response, W, Lane, Request, Viewer, W.Global_Count (1));
            Answer (Batch, Index);
         when List_Ask =>
            Write_List (Into    => Batch (Index).Response,
                        W       => W,
                        Lane    => Lane,
                        Request => Request,
                        Viewer  => Viewer,
                        Count   => (if Request.Count_Key in Batch_Index
                                    then W.List_Counts (Request.Filter) (Request.Count_Key) else 0));
            Answer (Batch, Index);
         when Feed_Ask =>
            Write_List (Into    => Batch (Index).Response,
                        W       => W,
                        Lane    => Lane,
                        Request => Request,
                        Viewer  => Viewer,
                        Count   => (if Request.Viewer_Key in Batch_Index
                                    then W.Feed_Counts (Request.Viewer_Key) else 0));
            Answer (Batch, Index);
      end case;
   end Render_Job;

   ---------------------------------------------------------------------------------------------------------------
   --  the batch

   ------------------
   -- Send_Phase_A --
   ------------------

   --  Phase A: queue a statement per kind of key present, the early group (answered first) before a Sync.
   procedure Send_Phase_A (W : in out Workspace; Lane : in out Connection; Early_Results : out Result_Slot) is begin
      if W.Want_Tags then
         Run (W, Lane, Tags);
      end if;
      if Numbers.Length (W.User_Keys) > 0 then
         Run (W, Lane, Users);
      end if;
      if Text_Sets.Length (W.Login_Keys) > 0 then
         Run (W, Lane, Logins);
      end if;

      Early_Results := W.Result_Count;
      Sync (Lane);

      if not W.Want_Tags
        and then (for some Index in Batch_Index =>
                    W.Asks (Index).Kind in Slug_Ask | Id_Ask | Global_Ask | List_Ask | Feed_Ask)
      then
         Run (W, Lane, Tags);
      end if;
      if Text_Sets.Length (W.Profile_Keys) > 0 then
         Run (W, Lane, Profiles);
      end if;
      if Text_Sets.Length (W.Slug_Keys) > 0 then
         Run (W, Lane, Slugs);
      end if;
      if Numbers.Length (W.Id_Keys) > 0 then
         Run (W, Lane, Ids);
      end if;
      if Text_Sets.Length (W.Thread_Keys) > 0 then
         Run (W, Lane, Threads);
      end if;
      if Triples.Length (W.Global_Pages) > 0 then
         Run (W, Lane, Global);
      end if;
      for Filter in Filtered loop
         if Triples.Length (W.List_Pages (Filter)) > 0 then
            Run (W, Lane, List_Statement_Of (Filter));
         end if;
      end loop;
      if Numbers.Length (W.Feed_Viewers) > 0 then
         Run (W, Lane, Feeds);
      end if;

      Sync (Lane);
   end Send_Phase_A;

   ------------------
   -- Answer_Batch --
   ------------------

   procedure Answer_Batch (W      : in out Workspace;
                           Lane   : in out Connection;
                           Batch  : in out Job_List;
                           Failed : in out Boolean)
      with Pre => Shaped (Batch)
   is
      Early_Results : Result_Slot;
      Sent          : Boolean;
      Done          : Boolean;
   begin
      Plan (W, Batch);
      Send_Phase_A (W, Lane, Early_Results);
      Try_Flush (Lane, Sent);
      if not Sent then
         Log ("postgres (reads): " & Last_Failure (Lane));
         Failed := True;
         return;
      end if;

      Read (W, Lane, 1, Early_Results, False, Failed);
      if Failed then
         return;
      end if;

      if not Succeeded (W.Results, 1, Early_Results) then
         Log ("planner: early statement failed");
         Answer_Rest (Batch, Internal_Server_Error);
         Read (W, Lane, Early_Results + 1, W.Result_Count, True, Failed);
         return;
      end if;

      Answer_Early (W, Lane, Batch);
      Read (W, Lane, Early_Results + 1, W.Result_Count, True, Failed);
      if Failed then
         return;
      end if;

      if not Succeeded (W.Results, Early_Results + 1, W.Result_Count) then
         Log ("planner: phase A statement failed");
         Answer_Rest (Batch, Internal_Server_Error);
         return;
      end if;

      if (for all Index in Batch'Range => Batch (Index) = null) then
         return;
      end if;

      Decode_Phase_A (W, Lane);
      Plan_Phase_B (W, Lane, Batch);
      Run_Phase_B (W, Lane, Batch, Failed, Done);
      if not Done then
         return;
      end if;

      Decode_Phase_B (W, Lane);
      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Render_Job (W, Lane, Batch, Index);
         end if;
      end loop;
   end Answer_Batch;

   -------------
   -- Execute --
   -------------

   procedure Execute (Work   : in out Workspace;
                      Lane   : in out Postgres.Connection;
                      Batch  : in out Job_List;
                      Failed : out Boolean)
   is begin
      Failed := False;
      Start_Batch (Work, Batch'Length);
      Answer_Batch (Work, Lane, Batch, Failed);
      Answer_Rest (Batch, Internal_Server_Error);   --  whatever a failure left unanswered
   end Execute;

end Planner;
