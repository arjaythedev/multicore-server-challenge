--  The batch read planner. A read lane takes every read job waiting and answers the whole batch in two
--  pipelined round trips:
--
--  - phase A resolves what each job is about, one statement per kind of job present, over arrays of the
--    batch's distinct keys (one lookup per slug, one page per (filter, key, limit, offset), one count per key);
--  - phase B enriches the union of every article phase A returned, once each (tags, favorites count, author),
--    plus the viewers' favorited / following flags as primary-key probes.
--
--  Tag lists, current users and login lookups are answered after a first Sync, before the rest of phase A.
--  Every value in a response was read from Postgres during that job's batch; nothing outlives the batch but
--  the memory of the lane's Workspace, which the next batch resets.
--
--  Proved free of run-time errors (SPARK silver), whatever Postgres returns, and to hand every job of the batch
--  on: none is lost or kept.
with Interfaces;
with Index_Sets;
with Jobs;
with Model;
with Postgres;
with Row_Groups;
with Text_Sets;

package Planner with SPARK_Mode is

   Max_Batch : constant := 1024;

   subtype Job_List is Jobs.Job_List;

   --  What a read lane keeps between batches: the sets and tables a batch fills. They are reset, not freed, so
   --  once they have grown to the lane's usual batch a batch allocates nothing for them.
   type Workspace is limited private;

   --  Answer every job of Batch (logins go on to the hashers instead); the jobs are handed on, so Batch is all
   --  null afterwards. Failed when the connection failed: the jobs not answered by then got a 500, and the
   --  connection needs reopening.
   procedure Execute (Work   : in out Workspace;
                      Lane   : in out Postgres.Connection;
                      Batch  : in out Job_List;
                      Failed : out Boolean)
      with
        Pre  => Batch'First = 1 and then Batch'Last <= Max_Batch,
        Post => (for all Index in Batch'Range => Jobs."=" (Batch (Index), null));

private

   use Interfaces;

   ---------------------------------------------------------------------------------------------------------------
   --  keys

   function Mix (Value : Long_Long_Integer) return Unsigned_64 is
     (Unsigned_64'Mod (Value) * 16#9E37_79B9_7F4A_7C15#
      xor Shift_Right (Unsigned_64'Mod (Value) * 16#9E37_79B9_7F4A_7C15#, 29));

   --  (viewer, article), (viewer, author), (viewer, comment thread).
   type Pair is record
      Left, Right : Long_Long_Integer := 0;
   end record;

   function Hash (Item : Pair) return Unsigned_64 is (Mix (Item.Left) * 31 + Mix (Item.Right));

   --  A page of a list: (key, limit, offset). The key is a list key's position, a viewer, or 0 (global).
   type Triple is record
      Key, Limit, Offset : Long_Long_Integer := 0;
   end record;

   function Hash (Item : Triple) return Unsigned_64 is
     ((Mix (Item.Key) * 31 + Mix (Item.Limit)) * 31 + Mix (Item.Offset));

   --  A row of a batch article statement: [k, id, author_id, slug, title, description, created_at, updated_at
   --  (, body)], in Results (Result).
   Max_Results : constant := 15;
   subtype Result_Slot is Natural range 0 .. Max_Results;   --  0: no such statement in this batch
   subtype Result_Table is Postgres.Result_Array (1 .. Max_Results);

   type Article_Row is record
      Result : Result_Slot := 0;
      Row    : Natural := 0;
   end record;

   package Numbers is new Index_Sets (Long_Long_Integer, 0, Mix, Natural, 0);            --  key -> a row
   package Authored is new Index_Sets (Long_Long_Integer, 0, Mix, Long_Long_Integer, 0); --  article -> author
   package Article_Index is new Index_Sets (Long_Long_Integer, 0, Mix, Article_Row, (0, 0));
   package Pairs is new Index_Sets (Pair, (0, 0), Hash, Natural, 0);
   package Triples is new Index_Sets (Triple, (0, 0, 0), Hash, Natural, 0);

   ---------------------------------------------------------------------------------------------------------------
   --  what each job asks phase A for

   subtype Filtered is Jobs.Filter_Kind range Jobs.By_Tag .. Jobs.By_Favoriter;

   type Ask_Kind is
     (No_Ask, Tags_Ask, User_Ask, Login_Ask, Profile_Ask, Slug_Ask, Id_Ask, Comments_Ask, Global_Ask, List_Ask,
      Feed_Ask);

   subtype Early_Ask is Ask_Kind range Tags_Ask .. Login_Ask;   --  answered after the first Sync
   subtype Keyed_Ask is Ask_Kind range User_Ask .. Global_Ask;

   --  Positions are 0 when the job could not be planned.
   type Ask (Kind : Ask_Kind := No_Ask) is record
      case Kind is
         when No_Ask | Tags_Ask =>
            null;
         when Keyed_Ask =>
            Key : Natural := 0;        --  position among that statement's keys
         when List_Ask =>
            Filter    : Filtered := Jobs.By_Tag;
            Count_Key : Natural := 0;  --  position among the filter's list keys
            Page_Key  : Natural := 0;  --  position among the filter's pages
         when Feed_Ask =>
            Viewer_Key : Natural := 0; --  position among the feed viewers
            Feed_Key   : Natural := 0; --  position among the feed pages
      end case;
   end record;

   --  Phase A statements, in the order they are sent; the first three are answered after the first Sync.
   type Phase_A_Statement is
     (Tags, Users, Logins, Profiles, Slugs, Ids, Threads, Global, Tag_Pages, Author_Pages, Favoriter_Pages, Feeds);
   subtype List_Statement is Phase_A_Statement range Tag_Pages .. Favoriter_Pages;

   type Phase_B_Statement is (Details, Flags, Article_Rows);

   subtype Batch_Index is Positive range 1 .. Max_Batch;

   type Ask_Array is array (Batch_Index) of Ask;
   type Row_Array is array (Batch_Index) of Natural;              --  a row per key, 0 when none
   type Count_Array is array (Batch_Index) of Long_Long_Integer;
   type Flag_Array is array (Batch_Index) of Boolean;
   type Slot_Array is array (Phase_A_Statement) of Result_Slot;
   type Slot_B_Array is array (Phase_B_Statement) of Result_Slot;
   type Text_Set_Array is array (Filtered) of Text_Sets.Set;
   type Triple_Set_Array is array (Filtered) of Triples.Set;
   type Group_Array is array (Filtered) of Row_Groups.Groups;
   type Count_Table is array (Filtered) of Count_Array;

   type Workspace is limited record
      Now  : Model.Unix_Seconds := 0;
      Asks : Ask_Array;

      --  phase A keys
      Want_Tags    : Boolean := False;
      User_Keys    : Numbers.Set;
      Login_Keys   : Text_Sets.Set;
      Profile_Keys : Text_Sets.Set;
      Slug_Keys    : Text_Sets.Set;
      Id_Keys      : Numbers.Set;
      Thread_Keys  : Text_Sets.Set;
      Thread_Views : Pairs.Set;   --  (viewer, thread) for signed-in comment readers
      Global_Pages : Triples.Set;
      List_Keys    : Text_Set_Array;
      List_Pages   : Triple_Set_Array;
      Feed_Viewers : Numbers.Set;
      Feed_Pages   : Triples.Set;

      --  results
      Results      : Result_Table;
      Slot         : Slot_Array := [others => 0];
      Slot_B       : Slot_B_Array := [others => 0];
      Result_Count : Result_Slot := 0;

      --  phase A answers
      Profiles_Found : Row_Array := [others => 0];
      Slugs_Found    : Row_Array := [others => 0];
      Ids_Found      : Row_Array := [others => 0];
      Global_Count   : Count_Array := [others => 0];
      Feed_Counts    : Count_Array := [others => 0];
      List_Counts    : Count_Table := [others => [others => 0]];
      Global_Rows    : Row_Groups.Groups;   --  rows per page, newest first
      List_Rows      : Group_Array;
      Feed_Rows      : Row_Groups.Groups;
      Thread_Rows    : Row_Groups.Groups;   --  rows per comment thread
      Thread_Exists  : Flag_Array := [others => False];
      Thread_Authors : Numbers.Set;         --  user id -> row
      Thread_Follows : Pairs.Set;           --  (viewer, author)

      --  phase B keys
      Articles      : Authored.Set;         --  article id -> author id
      Favorite_Asks : Pairs.Set;
      Follow_Asks   : Pairs.Set;
      Full_Rows     : Article_Index.Set;    --  article id -> a row with its columns
      Missing_Rows  : Numbers.Set;          --  feed articles nothing else returned columns for

      --  phase B answers
      Detail_Rows   : Numbers.Set;          --  article id -> row of Details
      Favorited_Set : Pairs.Set;
      Following_Set : Pairs.Set;
      Tag_Rank      : Numbers.Set;          --  tag id -> its row in Tags (name order)
   end record;

end Planner;
