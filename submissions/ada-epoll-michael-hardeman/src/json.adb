package body Json with SPARK_Mode is

   Max_Depth : constant := 32;

   ----------------
   -- Valid_Text --
   ----------------

   function Valid_Text (Text : String) return Boolean is
      Next : Natural := 0;   --  offset of the next sequence

      ----------
      -- Byte --
      ----------

      function Byte (Offset : Natural) return Natural is (Character'Pos (Text (Text'First + Offset)))
         with Pre => Offset < Text'Length;

      ---------------
      -- Continues --
      ---------------

      --  Whether the byte at Offset exists and is a continuation byte (10xxxxxx).
      function Continues (Offset : Natural) return Boolean is
        (Offset < Text'Length and then Byte (Offset) in 16#80# .. 16#BF#);
   begin

      while Next < Text'Length loop

         pragma Loop_Invariant (Next < Text'Length);
         pragma Loop_Variant (Increases => Next);

         declare
            Lead : constant Natural := Byte (Next);
         begin
            case Lead is
               when 16#00# =>
                  return False;
               when 16#01# .. 16#7F# =>
                  Next := Next + 1;
               when 16#C2# .. 16#DF# =>
                  if not Continues (Next + 1) then
                     return False;
                  end if;
                  Next := Next + 2;
               when 16#E0# .. 16#EF# =>
                  if not (Continues (Next + 1) and then Continues (Next + 2))
                    or else (Lead = 16#E0# and then Byte (Next + 1) < 16#A0#) --  overlong
                    or else (Lead = 16#ED# and then Byte (Next + 1) > 16#9F#) --  surrogate
                  then
                     return False;
                  end if;
                  Next := Next + 3;
               when 16#F0# .. 16#F4# =>
                  if not (Continues (Next + 1) and then Continues (Next + 2) and then Continues (Next + 3))
                    or else (Lead = 16#F0# and then Byte (Next + 1) < 16#90#) --  overlong
                    or else (Lead = 16#F4# and then Byte (Next + 1) > 16#8F#) --  above U+10FFFF
                  then
                     return False;
                  end if;
                  Next := Next + 4;
               when others =>
                  return False;
            end case;
         end;
      end loop;

      return True;
      end Valid_Text;

   -----------
   -- Parse --
   -----------

   procedure Parse (This : in out Document; Source : String; Valid : out Boolean) is
      Next   : Positive := Source'First; --  the next unread character of Source
      Failed : Boolean := False;         --  malformed, or over a capacity: the rest is skipped

      ------------
      -- At_End --
      ------------

      function At_End return Boolean is (Next > Source'Last);

      -------------
      -- Current --
      -------------

      function Current return Character is (Source (Next))
      with Pre => Next in Source'Range;

      ----------------
      -- Sizes_Hold --
      ----------------

      --  The sizes every step keeps within the document's capacities.
      function Sizes_Hold return Boolean is
        (Source'First >= 1 and then Source'Last < Positive'Last and then This.Text_Capacity < Positive'Last
         and then This.Node_Total <= This.Node_Capacity and then This.Text_Length <= This.Text_Capacity
         and then Next <= Source'Last + 1 and then Next >= Source'First);

      ------------
      -- Expect --
      ------------

      procedure Expect (Symbol : Character)
         with Pre => Sizes_Hold, Post => Sizes_Hold and then Next >= Next'Old
      is begin
         if At_End or else Current /= Symbol then
            Failed := True;
         else
            Next := Next + 1;
         end if;
      end Expect;

      ---------------------
      -- Skip_Whitespace --
      ---------------------

      procedure Skip_Whitespace
         with Pre => Sizes_Hold, Post => Sizes_Hold and then Next >= Next'Old
      is begin
         while not At_End and then Current in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
            pragma Loop_Invariant (Sizes_Hold and then Next >= Next'Loop_Entry);
            pragma Loop_Variant (Increases => Next);
            Next := Next + 1;
         end loop;
      end Skip_Whitespace;

      ---------
      -- Put --
      ---------

      procedure Put (Symbol : Character)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next = Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is begin
         if This.Text_Length >= This.Text_Capacity then
            Failed := True;
         else
            This.Text_Length             := This.Text_Length + 1;
            This.Text (This.Text_Length) := Symbol;
         end if;
      end Put;

      subtype Code_Point is Natural range 0 .. 16#10_FFFF#;

      --------------
      -- Put_Utf8 --
      --------------

      procedure Put_Utf8 (Point : Code_Point)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold 
                      and then Next = Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is

         ------------------
         -- Continuation --
         ------------------

         function Continuation (Bits : Natural) return Character is (Character'Val (16#80# + Bits mod 64));
      begin
         case Point is
            when 0 .. 16#7F# =>
               Put (Character'Val (Point));
            when 16#80# .. 16#7FF# =>
               Put (Character'Val (16#C0# + Point / 64));
               Put (Continuation (Point));
            when 16#800# .. 16#FFFF# =>
               Put (Character'Val (16#E0# + Point / 4096));
               Put (Continuation (Point / 64));
               Put (Continuation (Point));
            when others =>
               Put (Character'Val (16#F0# + Point / 262_144));
               Put (Continuation (Point / 4096));
               Put (Continuation (Point / 64));
               Put (Continuation (Point));
         end case;
      end Put_Utf8;

      --------------
      -- Hex_Quad --
      --------------

      --  The four hexadecimal digits of a \u escape.
      procedure Hex_Quad (Result : out Natural)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then Result < 16#1_0000#
      is
         Digit : Natural;
      begin
         Result := 0;
         for Count in 1 .. 4 loop
            pragma Loop_Invariant (Sizes_Hold and then Next >= Next'Loop_Entry and then Result < 16 ** (Count - 1));
            if At_End then
               Failed := True;
               return;
            end if;

            case Current is
               when '0' .. '9' => Digit := Character'Pos (Current) - Character'Pos ('0');
               when 'a' .. 'f' => Digit := Character'Pos (Current) - Character'Pos ('a') + 10;
               when 'A' .. 'F' => Digit := Character'Pos (Current) - Character'Pos ('A') + 10;
               when others =>
                  Failed := True;
                  return;
            end case;

            Result := Result * 16 + Digit;
            Next   := Next + 1;
         end loop;
      end Hex_Quad;

      --------------------
      -- Unicode_Escape --
      --------------------

      --  After a backslash and 'u': one escaped code point, joining a surrogate pair.
      procedure Unicode_Escape
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is
         High, Low : Natural;
      begin

         Hex_Quad (High);
         if Failed then
            return;
         end if;

         case High is
            when 16#D800# .. 16#DBFF# =>
               Expect ('\');
               Expect ('u');
               if Failed then
                  return;
               end if;

               Hex_Quad (Low);
               if Failed or else Low not in 16#DC00# .. 16#DFFF# then
                  Failed := True;
                  return;
               end if;

               Put_Utf8 (16#1_0000# + (High - 16#D800#) * 1024 + (Low - 16#DC00#));
            when 0 | 16#DC00# .. 16#DFFF# =>
               Failed := True; --  NUL, or a lone low surrogate
            when others =>
               Put_Utf8 (High);
         end case;
      end Unicode_Escape;

      ------------------
      -- Parse_String --
      ------------------

      --  At the opening quote: the string's decoded text.
      procedure Parse_String (Result : out Span)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
                      and then (if not Failed then Result.Last <= This.Text_Length)
      is
         First : constant Positive := This.Text_Length + 1;
      begin
         Result := (First => First, Last => First - 1);
         Expect ('"');

         loop
            pragma Loop_Invariant (Sizes_Hold 
                                   and then Next >= Next'Loop_Entry
                                   and then This.Text_Length >= First - 1
                                   and then This.Node_Total = This.Node_Total'Loop_Entry);
            pragma Loop_Variant (Increases => Next);

            if Failed then
               return;
            elsif At_End then
               Failed := True;
               return;
            end if;

            case Current is
               when '"' =>
                  Next := Next + 1;
                  exit;
               when '\' =>
                  Next := Next + 1;
                  if At_End then
                     Failed := True;
                     return;
                  end if;

                  declare
                     Escaped : constant Character := Current;
                  begin
                     Next := Next + 1;
                     case Escaped is
                        when '"' | '\' | '/' => Put (Escaped);
                        when 'b' => Put (ASCII.BS);
                        when 'f' => Put (ASCII.FF);
                        when 'n' => Put (ASCII.LF);
                        when 'r' => Put (ASCII.CR);
                        when 't' => Put (ASCII.HT);
                        when 'u' => Unicode_Escape;
                        when others => Failed := True;
                     end case;
                  end;
               when ASCII.NUL .. Character'Val (31) =>
                  Failed := True;
                  return;
               when others =>
                  Put (Current);
                  Next := Next + 1;
            end case;
         end loop;

         if not Valid_Text (This.Text (First .. This.Text_Length)) then
            Failed := True;
            return;
         end if;

         Result := (First => First, Last => This.Text_Length);
      end Parse_String;

      --------------
      -- New_Node --
      --------------

      procedure New_Node (Of_Kind : Kind; Item : out Node_Count)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next = Next'Old
                      and then This.Text_Length = This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is begin
         Item := No_Node;
         if This.Node_Total >= This.Node_Capacity then
            Failed := True;
            return;
         end if;

         This.Node_Total              := This.Node_Total + 1;
         This.Nodes (This.Node_Total) := (Of_Kind => Of_Kind, others => <>);
         Item                         := This.Node_Total;
      end New_Node;

      -------------------
      -- Parse_Literal --
      -------------------

      procedure Parse_Literal (Word : String; Of_Kind : Kind; Item : out Node_Count)
         with Pre  => Sizes_Hold
                      and then Word'First = 1
                      and then Word'Length in 1 .. 5,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length = This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is begin
         Item := No_Node;
         if Source'Last - Next + 1 < Word'Length or else Source (Next .. Next + (Word'Length - 1)) /= Word then
            Failed := True;
            return;
         end if;

         Next := Next + Word'Length;
         New_Node (Of_Kind, Item);
      end Parse_Literal;

      ------------------
      -- Parse_Number --
      ------------------

      procedure Parse_Number (Item : out Node_Count)
         with Pre  => Sizes_Hold and then not At_End,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is
         First     : constant Positive := This.Text_Length + 1;
         Saw_Digit : Boolean := False;
      begin
         New_Node (Number_Kind, Item);
         if Failed then
            return;
         end if;

         if Current = '-' then
            Put (Current);
            Next := Next + 1;
         end if;

         while not Failed and then not At_End and then Current in '0' .. '9' | '.' | 'e' | 'E' | '+' | '-' loop
            pragma Loop_Invariant
              (Sizes_Hold and then Next >= Next'Loop_Entry and then This.Text_Length >= First - 1
               and then Item in 1 .. This.Node_Total and then This.Node_Total = This.Node_Total'Loop_Entry);
            pragma Loop_Variant (Increases => Next);
            Saw_Digit := Saw_Digit or else Current in '0' .. '9';
            Put (Current);
            Next := Next + 1;
         end loop;

         if not Saw_Digit then
            Failed := True;
            return;
         end if;

         This.Nodes (Item).Value := (First => First, Last => This.Text_Length);
      end Parse_Number;

      -----------------
      -- Parse_Value --
      -----------------

      --  One value and, for arrays and objects, everything inside it.
      procedure Parse_Value (Depth : Natural; Item : out Node_Count)
         with Subprogram_Variant => (Decreases => Max_Depth - Depth),
              Pre  => Sizes_Hold and then Depth <= Max_Depth,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is
         Closing  : Character;
         Previous : Node_Count := No_Node;
         Child    : Node_Count;
         Key      : Span;
      begin
         Item := No_Node;
         Skip_Whitespace;
         if Failed or else At_End then
            Failed := True;
            return;
         end if;

         case Current is
            when '{' | '[' =>
               Closing := (if Current = '{' then '}' else ']');
               New_Node ((if Closing = '}' then Object_Kind else Array_Kind), Item);
               if Failed then
                  return;
               end if;

               Next := Next + 1;   --  the opening bracket
               Skip_Whitespace;
               if not At_End and then Current = Closing then
                  Next := Next + 1;
                  return;
               end if;

               loop
                  pragma Loop_Invariant
                    (Sizes_Hold and then Next >= Next'Loop_Entry and then Item in 1 .. This.Node_Total
                     and then Previous <= This.Node_Total and then This.Text_Length >= This.Text_Length'Loop_Entry
                     and then This.Node_Total >= This.Node_Total'Loop_Entry);
                  pragma Loop_Variant (Increases => Next);
                  if Depth = Max_Depth then
                     Failed := True;   --  nested too deeply
                     return;
                  end if;

                  Key := (First => 1, Last => 0);
                  if Closing = '}' then
                     Skip_Whitespace;
                     Parse_String (Key);
                     Skip_Whitespace;
                     Expect (':');
                     if Failed then
                        return;
                     end if;
                  end if;

                  Parse_Value (Depth + 1, Child);
                  if Failed then
                     return;
                  end if;

                  This.Nodes (Child).Key := Key;
                  if Previous = No_Node then
                     This.Nodes (Item).First_Child := Child;
                  else
                     This.Nodes (Previous).Next_Sibling := Child;
                  end if;
                  Previous := Child;

                  Skip_Whitespace;
                  if At_End then
                     Failed := True;
                     return;
                  elsif Current = Closing then
                     Next := Next + 1;
                     return;
                  elsif Current /= ',' then
                     Failed := True;
                     return;
                  end if;

                  Next := Next + 1;
                  end loop;
            when '"' =>
               New_Node (String_Kind, Item);
               if Failed then
                  return;
               end if;
               Parse_String (Key);
               if not Failed then
                  This.Nodes (Item).Value := Key;
               end if;
            when 't' =>
               Parse_Literal ("true", True_Kind, Item);
            when 'f' =>
               Parse_Literal ("false", False_Kind, Item);
            when 'n' =>
               Parse_Literal ("null", Null_Kind, Item);
            when '-' | '0' .. '9' =>
               Parse_Number (Item);
            when others =>
               Failed := True;
         end case;
      end Parse_Value;

      Top : Node_Count;
   begin
      Valid := False;
      if Source'Length = 0 then
         return;
      end if;

      This.Node_Total  := 0;
      This.Text_Length := 0;
      Parse_Value (0, Top);
      Skip_Whitespace;
      Valid := not Failed and then At_End and then Top = Root;
   end Parse;

   ------------
   -- Exists --
   ------------

   function Exists (This : Document; Item : Node_Count) return Boolean is
     (Item /= No_Node and then Item <= This.Node_Total and then Item <= This.Node_Capacity);

   -------------
   -- Text_Of --
   -------------

   --  The text a span names, or "" when it is empty or outside the document's text.
   function Text_Of (This : Document; Item : Span) return String is
     (if Item.Last < Item.First
         or else Item.Last > This.Text_Length
         or else Item.Last > This.Text_Capacity
      then ""
      else This.Text (Item.First .. Item.Last));

   -------------
   -- Kind_Of --
   -------------

   function Kind_Of (This : Document; Item : Node_Count) return Kind is
     (if Exists (This, Item) then This.Nodes (Item).Of_Kind else Null_Kind);

   -----------
   -- Value --
   -----------

   function Value (This : Document; Item : Node_Count) return String is
     (if Exists (This, Item) then Text_Of (This, This.Nodes (Item).Value) else "");

   -----------------
   -- First_Child --
   -----------------

   --  Links only ever point forward to nodes parsed later; anything else reads as no node.
   function First_Child (This : Document; Item : Node_Count) return Node_Count is
     (if Exists (This, Item)
         and then This.Nodes (Item).First_Child > Item
      then This.Nodes (Item).First_Child
      else No_Node);

   ------------------
   -- Next_Sibling --
   ------------------

   function Next_Sibling (This : Document; Item : Node_Count) return Node_Count is
     (if Exists (This, Item)
         and then This.Nodes (Item).Next_Sibling > Item
      then This.Nodes (Item).Next_Sibling
      else No_Node);

   ------------
   -- Member --
   ------------

   function Member (This : Document; Object : Node_Count; Name : String) return Node_Count is
      Child : Node_Count;
   begin
      if Kind_Of (This, Object) /= Object_Kind then
         return No_Node;
      end if;
      Child := First_Child (This, Object);
      while Exists (This, Child) loop
         pragma Loop_Variant (Increases => Child);
         if Text_Of (This, This.Nodes (Child).Key) = Name then
            return Child;
         end if;
         Child := Next_Sibling (This, Child);
      end loop;
      return No_Node;
   end Member;

end Json;
