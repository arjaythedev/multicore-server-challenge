with Bcrypt;
with Buffers; use Buffers;
with Jwt;
with Model; use Model;

package body Api with SPARK_Mode is

   use Http;
   use Jobs;
   use Json;

   type Authentication_Policy is (Ignored, Optional, Required);

   Authentication : constant array (Endpoint) of Authentication_Policy := [
      Register    | Login         | List_Tags                   => Ignored,
      Get_Profile | List_Articles | Get_Article | List_Comments => Optional,
                                                         others => Required];

   subtype Hex_Digit is Integer range -1 .. 15;   --  -1: not a hex digit

   ---------------
   -- Hex_Value --
   ---------------

   function Hex_Value (Symbol : Character) return Hex_Digit is
     (case Symbol is
         when '0' .. '9' => Character'Pos (Symbol) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Symbol) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Symbol) - Character'Pos ('A') + 10,
         when others => -1);

   --------------------
   -- Percent_Decode --
   --------------------

   --  Percent-decoding into Into (1 .. Last); in a query string '+' is a space as well. Valid is False on a bad
   --  escape.
   procedure Percent_Decode (Text     : String;
                             In_Query : Boolean;
                             Into     : out String;
                             Last     : out Natural;
                             Valid    : out Boolean)
      with Pre  => Into'First = 1 and then Into'Last >= Text'Length,
           Post => Last <= Text'Length
   is
      Next : Natural := 0; --  offset in Text of the next character
   begin
      Into  := [others => ' '];
      Last  := 0;
      Valid := True;

      while Next < Text'Length loop
         pragma Loop_Invariant (Last <= Next);
         pragma Loop_Variant (Increases => Next);
         Last := Last + 1;
         declare
            Symbol : constant Character := Text (Text'First + Next);
         begin
            if Symbol = '%' then
               if Text'Length - Next < 3
                 or else Hex_Value (Text (Text'First + Next + 1)) < 0
                 or else Hex_Value (Text (Text'First + Next + 2)) < 0
               then
                  Valid := False;
                  Last  := 0;
                  return;
               end if;

               Into (Last) := Character'Val (16 * Hex_Value (Text (Text'First + Next + 1)) 
                                                + Hex_Value (Text (Text'First + Next + 2)));
               Next := Next + 3;
            else
               Into (Last) := (if In_Query and then Symbol = '+' then ' ' else Symbol);
               Next        := Next + 1;
            end if;
         end;
      end loop;
   end Percent_Decode;

   ----------------
   -- All_Digits --
   ----------------

   function All_Digits (Text : String) return Boolean is (for all Symbol of Text => Symbol in '0' .. '9');

   -----------------
   -- Is_Key_Text --
   -----------------

   --  Digits for a bigint key: at most 18, so the value always fits.
   function Is_Key_Text (Text : String) return Boolean is (Text'Length in 1 .. 18 and then All_Digits (Text));

   Max_Key : constant := 10 ** 18 - 1;

   Powers : constant array (0 .. 18) of Long_Long_Integer :=
     [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000,
      100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000, 1_000_000_000_000_000,
      10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000];

   ---------------
   -- Key_Value --
   ---------------

   function Key_Value (Text : String) return Long_Long_Integer
      with Pre  => Is_Key_Text (Text), 
           Post => Key_Value'Result in 0 .. Max_Key
   is
      Value : Long_Long_Integer := 0;
   begin
      for Offset in 0 .. Text'Length - 1 loop
         pragma Loop_Invariant (Value in 0 .. Powers (Offset) - 1);
         Value := Value * 10 + Long_Long_Integer (Character'Pos (Text (Text'First + Offset)) - Character'Pos ('0'));
         pragma Assert (Powers (Offset + 1) = Powers (Offset) * 10);
      end loop;
      return Value;
   end Key_Value;

   Token_Scheme : constant String := "Token ";   --  Authorization: Token <jwt>

   -----------
   -- Route --
   -----------

   procedure Route (Request  : String;
                    Head     : Http.Request_Head;
                    Now      : Model.Unix_Seconds;
                    Document : in out Json.Document;
                    Result   : out Routing)
   is

      ------------
      -- Shaped --
      ------------

      --  Route's precondition, for the nested subprograms: none of it changes.
      function Shaped return Boolean is
        (Request'First = 1 and then Request'Last < Positive'Last
         and then Head.Outcome = Http.Complete
         and then Head.Head_Length <= Request'Length
         and then Http.Within (Head.Path, Request)
         and then Http.Within (Head.Query, Request)
         and then Http.Within (Head.Authorization, Request)
         and then Document.Text_Capacity < Positive'Last);

      --  The spans as slices; an empty span may have any bounds, so it becomes 1 .. 0.
      Path    : String renames Request ((if Length (Head.Path) = 0 then 1 else Head.Path.First) 
                                        .. 
                                        (if Length (Head.Path) = 0 then 0 else Head.Path.Last));

      Query   : String renames Request ((if Length (Head.Query) = 0 then 1 else Head.Query.First)
                                        .. 
                                        (if Length (Head.Query) = 0 then 0 else Head.Query.Last));

      Payload : String renames Request (Head.Head_Length + 1 .. Request'Last);

      Failed  : Boolean := False;
      Failure : Status_Code := Internal_Server_Error;

      ------------
      -- Reject --
      ------------

      --  The first rejection decides the status.
      procedure Reject (Status : Status_Code) is begin
         if not Failed then
            Failed  := True;
            Failure := Status;
         end if;
      end Reject;

      Max_Segments : constant := 8;
      Segments     : array (1 .. Max_Segments) of Http.Span := [others => (1, 0)];
      Count        : Natural range 0 .. Max_Segments := 0;

      -------------
      -- Segment --
      -------------

      function Segment (Index : Positive) return String is
        (if Index <= Max_Segments                and then 
            Segments (Index).First >= Path'First and then
            Segments (Index).Last <= Path'Last
         then Request (Segments (Index).First .. Segments (Index).Last)
         else "")
         with Pre  => Shaped, 
              Post => Segment'Result'Length <= Path'Length;

      ----------------
      -- Split_Path --
      ----------------

      procedure Split_Path
      with Pre => Shaped
      is
         Prefix : constant String := "/api/";
         First  : Positive;
         Last   : Positive;
      begin
         if Path'Length < Prefix'Length or else Path (Path'First .. Path'First + Prefix'Length - 1) /= Prefix then
            Reject (Not_Found);
            return;
         end if;

         First := Path'First + Prefix'Length;
         while First <= Path'Last loop
            pragma Loop_Invariant (First >= Path'First);
            pragma Loop_Variant (Increases => First);
            Last := First;
            while Last <= Path'Last and then Path (Last) /= '/' loop
               pragma Loop_Invariant (Last in First .. Path'Last);
               pragma Loop_Variant (Increases => Last);
               Last := Last + 1;
            end loop;

            if Last > First then   --  empty segments are skipped
               if Count = Max_Segments then
                  Reject (Not_Found);
                  return;
               end if;
               Count            := Count + 1;
               Segments (Count) := (First, Last - 1);
            end if;

            exit when Last >= Path'Last;
            First := Last + 1;
         end loop;

         if Count = 0 then
            Reject (Not_Found);
         end if;
      end Split_Path;

      -------------------
      -- Find_Endpoint --
      -------------------

      procedure Find_Endpoint (Kind : out Endpoint; Found : out Boolean) with Pre => Shaped is
         Verb : constant Method := Head.Verb;
         Root : constant String := Segment (1);

         ----------
         -- Pick --
         ----------

         procedure Pick (Result : Endpoint) is begin
            Kind  := Result;
            Found := True;
         end Pick;
      begin
         Kind  := List_Tags;
         Found := False;

         if Root = "tags" and then Count = 1 and then Verb = Get then
            Pick (List_Tags);
         elsif Root = "users" and then Verb = Post then
            if Count = 1 then
               Pick (Register);
            elsif Count = 2 and then Segment (2) = "login" then
               Pick (Login);
            end if;
         elsif Root = "user" and then Count = 1 then
            case Verb is
               when Get    => Pick (Current_User);
               when Put    => Pick (Update_User);
               when others => null;
            end case;
         elsif Root = "profiles" then
            if Count = 2 and then Verb = Get then
               Pick (Get_Profile);
            elsif Count = 3 and then Segment (3) = "follow" then
               case Verb is
                  when Post   => Pick (Follow);
                  when Delete => Pick (Unfollow);
                  when others => null;
               end case;
            end if;
         elsif Root = "articles" then
            case Count is
               when 1 =>
                  case Verb is
                     when Get    => Pick (List_Articles);
                     when Post   => Pick (Create_Article);
                     when others => null;
                  end case;
               when 2 =>
                  case Verb is
                     when Get    => Pick (if Segment (2) = "feed" then Feed else Get_Article);
                     when Put    => Pick (Update_Article);
                     when Delete => Pick (Delete_Article);
                     when others => null;
                  end case;
               when 3 =>
                  if Segment (3) = "favorite" then
                     case Verb is
                        when Post   => Pick (Favorite);
                        when Delete => Pick (Unfavorite);
                        when others => null;
                     end case;
                  elsif Segment (3) = "comments" then
                     case Verb is
                        when Get    => Pick (List_Comments);
                        when Post   => Pick (Add_Comment);
                        when others => null;
                     end case;
                  end if;
               when 4 =>
                  if Segment (3) = "comments" and then Verb = Delete then
                     Pick (Delete_Comment);
                  end if;
               when others =>
                  null;
            end case;
         end if;
      end Find_Endpoint;

      --  The body's JSON --------------------------------------------------------------------------------------

      Object : Node_Count := No_Node;   --  under the wrapper key

      ------------
      -- Unwrap --
      ------------

      --  Parse the body and find the object under its wrapper key ({"user": {...}}), or 422.
      procedure Unwrap (Name : String) with Pre => Shaped is
         Valid : Boolean;
      begin
         Parse (Document, Payload, Valid);
         if not Valid then
            Reject (Unprocessable_Content);
            return;
         end if;

         Object := Member (Document, Json.Root, Name);
         if Kind_Of (Document, Object) /= Object_Kind then
            Reject (Unprocessable_Content);
         end if;
      end Unwrap;

      -------------
      -- Require --
      -------------

      --  A member that must be a non-empty string.
      procedure Require (Name : String) is
         Item : constant Node_Count := Member (Document, Object, Name);
      begin
         if Kind_Of (Document, Item) /= String_Kind or else Value (Document, Item)'Length = 0 then
            Reject (Unprocessable_Content);
         end if;
      end Require;

      -----------
      -- Allow --
      -----------

      --  A member that may be absent or null; otherwise a string, non-empty unless Allow_Empty.
      procedure Allow (Name : String; Allow_Empty : Boolean) is
         Item : constant Node_Count := Member (Document, Object, Name);
      begin
         case Kind_Of (Document, Item) is
            when Null_Kind =>
               null;
            when String_Kind =>
               if not Allow_Empty and then Value (Document, Item)'Length = 0 then
                  Reject (Unprocessable_Content);
               end if;
            when others =>
               Reject (Unprocessable_Content);
         end case;
      end Allow;

      ---------------------------
      -- Check_Password_Length --
      ---------------------------

      procedure Check_Password_Length is
         Item : constant Node_Count := Member (Document, Object, "password");
      begin
         if Kind_Of (Document, Item) = String_Kind
         and then Value (Document, Item)'Length > Bcrypt.Max_Password_Length 
         then
            Reject (Unprocessable_Content);
         end if;
      end Check_Password_Length;

      Tag_List  : Node_Count := No_Node;
      Tag_Count : Natural := 0;

      ----------------
      -- Check_Tags --
      ----------------

      --  "tagList": null or absent, or an array of non-empty strings.
      procedure Check_Tags is
         Item : Node_Count;
      begin
         Tag_Count := 0;
         Tag_List  := Member (Document, Object, "tagList");

         case Kind_Of (Document, Tag_List) is
            when Null_Kind =>
               null;
            when Array_Kind =>
               Item := First_Child (Document, Tag_List);
               while Item /= No_Node loop

                  pragma Loop_Invariant (Tag_Count < Natural (Item));
                  pragma Loop_Variant (Increases => Item);

                  if Kind_Of (Document, Item) /= String_Kind
                  or else Value (Document, Item)'Length = 0 
                  then
                     Reject (Unprocessable_Content);
                     return;
                  end if;

                  Tag_Count := Tag_Count + 1;
                  Item      := Next_Sibling (Document, Item);
               end loop;
            when others =>
               Reject (Unprocessable_Content);
         end case;
      end Check_Tags;

      --  The path's second segment as stored text ---------------------------------------------------------------

      Name      : String (1 .. Path'Length) := [others => ' '];
      Name_Last : Natural := 0;

      ---------------
      -- Take_Name --
      ---------------

      --  A name Postgres could not store matches no row: 404.
      procedure Take_Name
         with Pre => Shaped
      is
         Valid : Boolean;
      begin
         Percent_Decode (Segment (2), In_Query => False, Into => Name, Last => Name_Last, Valid => Valid);
         if not Valid or else not Valid_Text (Name (1 .. Name_Last)) then
            Reject (Not_Found);
         end if;
      end Take_Name;

      --  The query string -------------------------------------------------------------------------------------

      ---------------------
      -- Query_Parameter --
      ---------------------

      --  The first occurrence of query parameter Name, percent-decoded into Into (1 .. Last); Found is False when
      --  there is none. A value that does not decode is a 422.
      procedure Query_Parameter (Name : String; Into : out String; Last : out Natural; Found : out Boolean)
         with Pre  => Shaped and then Into'First = 1 and then Into'Last >= Query'Length,
              Post => Last <= Into'Last
      is
         First : Positive := Query'First;
         Valid : Boolean;
      begin
         Into  := [others => ' '];
         Last  := 0;
         Found := False;

         while First <= Query'Last loop

            pragma Loop_Variant (Increases => First);
            pragma Loop_Invariant (First >= Query'First and then Last = 0);

            declare
               Ampersand : Positive := First;
               Equals    : Natural := 0;
            begin
               while Ampersand <= Query'Last and then Query (Ampersand) /= '&' loop

                  pragma Loop_Variant (Increases => Ampersand);
                  pragma Loop_Invariant (
                     Ampersand in First .. Query'Last and then Equals in 0 | First .. Ampersand - 1);

                  if Equals = 0 and then Query (Ampersand) = '=' then
                     Equals := Ampersand;
                  end if;
                  Ampersand := Ampersand + 1;
               end loop;

               declare
                  Key_Last   : constant Natural := (if Equals = 0 then Ampersand else Equals) - 1;
                  Key        : String (1 .. Query'Length);
                  Key_Length : Natural;
               begin
                  Percent_Decode (Query (First .. Key_Last), True, Key, Key_Length, Valid);
                  if Valid and then Key (1 .. Key_Length) = Name then
                     Found := True;
                     if Equals /= 0 then
                        Percent_Decode (Query (Equals + 1 .. Ampersand - 1), True, Into, Last, Valid);
                        if not Valid then
                           Reject (Unprocessable_Content);
                        end if;
                     end if;
                     return;
                  end if;
               end;

               exit when Ampersand >= Query'Last;
               First := Ampersand + 1;
            end;
         end loop;
      end Query_Parameter;

      ----------------------
      -- Number_Parameter --
      ----------------------

      --  A query parameter of digits only (no sign, no spaces), or Default when absent.
      procedure Number_Parameter (Name : String; Default : Long_Long_Integer; Result : out Long_Long_Integer)
         with Pre  => Shaped and then Default in 0 .. Max_Key,
              Post => Result in 0 .. Max_Key
      is
         Text  : String (1 .. Query'Length);
         Last  : Natural;
         Found : Boolean;
      begin
         Result := Default;
         Query_Parameter (Name, Text, Last, Found);

         if not Found then
            return;
         elsif not Is_Key_Text (Text (1 .. Last)) then
            Reject (Unprocessable_Content);
            return;
         end if;
         Result := Key_Value (Text (1 .. Last));
      end Number_Parameter;

      Page : Page_Window;

      ---------------
      -- Take_Page --
      ---------------

      procedure Take_Page with Pre => Shaped is
         Limit, Offset : Long_Long_Integer;
      begin
         Number_Parameter ("limit", 20, Limit);
         if Limit not in Long_Long_Integer (Page_Limit'First) .. Long_Long_Integer (Page_Limit'Last) then
            Reject (Unprocessable_Content);
            return;
         end if;

         Number_Parameter ("offset", 0, Offset);
         Page := (Limit => Page_Limit (Limit), Offset => Page_Offset (Offset));
      end Take_Page;

      subtype Filtered is Filter_Kind range By_Tag .. By_Favoriter;

      Filter      : Filter_Kind := No_Filter;
      Filter_Text : String (1 .. Query'Length) := [others => ' '];
      Filter_Last : Natural := 0;

      -----------------
      -- Take_Filter --
      -----------------

      --  ?tag=, ?author= or ?favorited=, the first present and non-empty in that order.
      procedure Take_Filter 
         with Pre  => Shaped, 
              Post => Filter_Last <= Filter_Text'Last
      is

         --------------------
         -- Parameter_Name --
         --------------------

         function Parameter_Name (Kind : Filtered) return String is
           (case Kind is
               when By_Tag       => "tag",
               when By_Author    => "author",
               when By_Favoriter => "favorited");
         Found : Boolean;
      begin
         for Kind in Filtered loop
            Query_Parameter (Parameter_Name (Kind), Filter_Text, Filter_Last, Found);
            if Found and then Filter_Last > 0 then   --  an empty filter is no filter
               Filter := Kind;
               --  text Postgres cannot hold matches no row: keep it out of the statement
               if not Valid_Text (Filter_Text (1 .. Filter_Last)) then
                  Filter_Last := 0;
               end if;
               return;
            end if;
         end loop;
         Filter_Last := 0;
      end Take_Filter;

      --  Building the job, once everything checked out ---------------------------------------------------------

      ----------
      -- Copy --
      ----------

      --  A string member's text; null when it is absent or JSON null.
      function Copy (Name : String) return String_Access is
         Item : constant Node_Count := Member (Document, Object, Name);
      begin
         if Kind_Of (Document, Item) /= String_Kind then
            return null;
         end if;
         return new String'(Value (Document, Item));
      end Copy;

      ---------------
      -- Copy_Name --
      ---------------

      function Copy_Name return String_Access is (new String'(Name (1 .. Natural'Min (Name_Last, Name'Last))));

      Kind        : Endpoint;
      Found       : Boolean;
      Token       : Jwt.Verdict := (Valid => False);
      Token_First : Positive := 1;
      Token_Last  : Natural := 0;

      -----------
      -- Build --
      -----------

      --  The job for a request that checked out.
      procedure Build (Kind : Endpoint; Into : out Routing)
         with Pre  => Shaped and then not Into'Constrained,
              Post => Into.Accepted and then Into.Work /= null
      is
         Filter_Value : constant String := Filter_Text (1 .. Natural'Min (Filter_Last, Filter_Text'Last));
         Token_Value  : constant String := (if Token_First >= Request'First 
                                            and then Token_Last <= Request'Last 
                                            then Request (Token_First .. Token_Last) else "");
         Work : Job (Kind);
      begin
         if Authentication (Kind) /= Ignored and then Token.Valid then
            Work.Viewer := Token.User;
         end if;

         case Kind is
            when Register =>
               Work.Account.Username := Copy ("username");
               Work.Account.Email    := Copy ("email");
               Work.Account.Password := Copy ("password");
               Work.Stage            := Hashing;
            when Login =>
               Work.Account.Email    := Copy ("email");
               Work.Account.Password := Copy ("password");
            when Current_User | Update_User =>
               Work.Account.Token := new String'(Token_Value);
               if Kind = Update_User then
                  Work.Account.Email    := Copy ("email");
                  Work.Account.Username := Copy ("username");
                  Work.Account.Password := Copy ("password");
                  Work.Account.Bio      := Copy ("bio");
                  Work.Account.Image    := Copy ("image");
                  Work.Stage            := (if Work.Account.Password /= null then Hashing else Writing);
               end if;
            when Get_Profile =>
               Work.Username := Copy_Name;
            when Follow | Unfollow =>
               Work.Username := Copy_Name;
               Work.Stage    := Writing;
            when List_Articles =>
               Work.Page := Page;
               case Filter is
                  when No_Filter    => null;
                  when By_Tag       => Work.Filter := (By_Tag, new String'(Filter_Value));
                  when By_Author    => Work.Filter := (By_Author, new String'(Filter_Value));
                  when By_Favoriter => Work.Filter := (By_Favoriter, new String'(Filter_Value));
               end case;
            when Feed =>
               Work.Page := Page;
            when Get_Article | List_Comments =>
               Work.Slug := Copy_Name;
            when Create_Article =>
               Work.Article.Title       := Copy ("title");
               Work.Article.Description := Copy ("description");
               Work.Article.Text        := Copy ("body");
               if Kind_Of (Document, Tag_List) = Array_Kind then
                  declare
                     Tags : constant String_List_Access := new String_List'(1 .. Tag_Count => null);
                     Item : Node_Count := First_Child (Document, Tag_List);
                  begin
                     for Index in 1 .. Tag_Count loop
                        pragma Loop_Invariant (Tags'First = 1 and then Tags'Last = Tag_Count
                                               and then (for all Later in Index .. Tag_Count => Tags (Later) = null));
                        Tags (Index) := new String'(Value (Document, Item));
                        Item         := Next_Sibling (Document, Item);
                     end loop;
                     Work.Article.Tags := Tags;
                  end;
               end if;
               Work.Stage := Writing;
            when Update_Article =>
               Work.Article.Title       := Copy ("title");
               Work.Article.Description := Copy ("description");
               Work.Article.Text        := Copy ("body");
               Work.Slug                := Copy_Name;
               Work.Stage               := Writing;
            when Delete_Article | Favorite | Unfavorite =>
               Work.Slug  := Copy_Name;
               Work.Stage := Writing;
            when Add_Comment =>
               Work.Comment_Body := Copy ("body");
               Work.Slug         := Copy_Name;
               Work.Stage        := Writing;
            when Delete_Comment =>
               if Is_Key_Text (Segment (4)) then   --  checked above
                  Work.Comment := Comment_Id (Key_Value (Segment (4)));
               end if;
               Work.Slug  := Copy_Name;
               Work.Stage := Writing;
            when List_Tags =>
               null;
         end case;

         Into := (Accepted => True, Work => new Job'(Work));
      end Build;

   begin
      Split_Path;
      if Failed then
         Result := (Accepted => False, Status => Failure);
         return;
      end if;

      Find_Endpoint (Kind, Found);
      if not Found then
         Result := (Accepted => False, Status => Not_Found);
         return;
      end if;

      if Head.Has_Authorization and then Length (Head.Authorization) > Token_Scheme'Length
        and then Request (Head.Authorization.First .. Head.Authorization.First + Token_Scheme'Length - 1)
                 = Token_Scheme
      then
         Token_First := Head.Authorization.First + Token_Scheme'Length;
         Token_Last  := Head.Authorization.Last;
         Token       := Jwt.Verify (Request (Token_First .. Token_Last), Now);
      end if;

      case Authentication (Kind) is
         when Ignored  => null;
         when Optional => if Head.Has_Authorization and then not Token.Valid then Reject (Unauthorized); end if;
         when Required => if not Token.Valid then Reject (Unauthorized); end if;
      end case;

      if Failed then
         Result := (Accepted => False, Status => Failure);
         return;
      end if;

      --  Validate: the first failure decides the status.
      case Kind is
         when Register =>
            Unwrap ("user");
            Require ("username");
            Require ("email");
            Require ("password");
            Check_Password_Length;
         when Login =>
            Unwrap ("user");
            Require ("email");
            Require ("password");
         when Current_User =>
            null;
         when Update_User =>
            Unwrap ("user");
            Allow ("email", Allow_Empty => False);
            Allow ("username", Allow_Empty => False);
            Allow ("password", Allow_Empty => False);
            Allow ("bio", Allow_Empty => True);
            Allow ("image", Allow_Empty => True);
            Check_Password_Length;
         when List_Articles =>
            Take_Page;
            Take_Filter;
         when Feed =>
            Take_Page;
         when Create_Article =>
            Unwrap ("article");
            Require ("title");
            Require ("description");
            Require ("body");
            Check_Tags;
         when Update_Article =>
            Unwrap ("article");
            Allow ("title", Allow_Empty => False);
            Allow ("description", Allow_Empty => False);
            Allow ("body", Allow_Empty => False);
            Take_Name;
         when Add_Comment =>
            Unwrap ("comment");
            Require ("body");
            Take_Name;
         when Delete_Comment =>
            if not Is_Key_Text (Segment (4)) then
               Reject (Not_Found);   --  no comment has such an id
            end if;
            Take_Name;
         when Get_Profile | Follow | Unfollow | Get_Article | List_Comments | Delete_Article | Favorite
            | Unfavorite
         =>
            Take_Name;
         when List_Tags =>
            null;
      end case;

      if Failed then
         Result := (Accepted => False, Status => Failure);
         return;
      end if;

      --  Build: nothing can fail from here on.
      Build (Kind, Result);
   end Route;

end Api;
