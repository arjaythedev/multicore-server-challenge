package body Http with SPARK_Mode is

   -----------------
   -- Status_Line --
   -----------------

   function Status_Line (Status : Status_Code) return String is
     ("HTTP/1.1 "
      & (case Status is
            when OK                    => "200 OK",
            when Created               => "201 Created",
            when No_Content            => "204 No Content",
            when Bad_Request           => "400 Bad Request",
            when Unauthorized          => "401 Unauthorized",
            when Forbidden             => "403 Forbidden",
            when Not_Found             => "404 Not Found",
            when Payload_Too_Large     => "413 Payload Too Large",
            when Unprocessable_Content => "422 Unprocessable Entity",
            when others                => "500 Internal Server Error")
      & CRLF);

   ----------------
   -- Error_Body --
   ----------------

   function Error_Body (Status : Status_Code) return String is
     ("{""errors"":{""body"":["""
      & (case Status is
            when Bad_Request           => "bad request",
            when Unauthorized          => "unauthorized",
            when Forbidden             => "forbidden",
            when Not_Found             => "not found",
            when Payload_Too_Large     => "payload too large",
            when Unprocessable_Content => "invalid request",
            when others                => "internal error")
      & """]}}");

   -----------
   -- Lower --
   -----------

   function Lower (Symbol : Character) return Character is
     (if Symbol in 'A' .. 'Z' then Character'Val (Character'Pos (Symbol) + 32) else Symbol);

   ---------------
   -- Same_Name --
   ---------------

   --  Case-insensitive comparison with a lower-case Name.
   function Same_Name (Text : String; Name : String) return Boolean is
     (Text'Length = Name'Length and then 
     (for all Offset in 0 .. Text'Length - 1 => Lower (Text (Text'First + Offset)) = Name (Name'First + Offset)));

   --------------------
   -- Contains_Token --
   --------------------

   function Contains_Token (Text : String; Token : String) return Boolean is
     (Token'Length > 0 and then Text'Length >= Token'Length and then 
     (for some First in Text'First .. Text'Last - Token'Length + 1 => 
         Same_Name (Text (First .. First + Token'Length - 1), Token)))
      with Pre => Text'Last < Positive'Last;

   ----------
   -- Find --
   ----------

   --  The position of the first Symbol in Text (From .. Before - 1), or Before.
   function Find (Text : String; Symbol : Character; From, Before : Positive) return Positive
      with Pre  => From >= Text'First and then From <= Before and then Before - 1 <= Text'Last,
           Post => Find'Result in From .. Before
                   and then (Find'Result = Before or else Text (Find'Result) = Symbol)
   is
      Position : Positive := From;
   begin
      while Position < Before and then Text (Position) /= Symbol loop
         pragma Loop_Invariant (Position in From .. Before - 1);
         pragma Loop_Variant (Increases => Position);
         Position := Position + 1;
      end loop;
      return Position;
   end Find;

   --  Content-Length: digits only (else 400), at most Max_Body_Length (else 413).
   type Length_Field (Valid : Boolean := False) is record
      case Valid is
         when True  => Value : Natural;
         when False => Status : Status_Code;
      end case;
   end record;

   --------------------
   -- Body_Length_Of --
   --------------------

   function Body_Length_Of (Text : String) return Length_Field is
      Value : Natural := 0;
   begin
      if Text'Length = 0 or else (for some Symbol of Text => Symbol not in '0' .. '9') then
         return (Valid => False, Status => Bad_Request);
      end if;

      for Symbol of Text loop
         pragma Loop_Invariant (Value <= Max_Body_Length);
         Value := Value * 10 + (Character'Pos (Symbol) - Character'Pos ('0'));
         if Value > Max_Body_Length then
            return (Valid => False, Status => Payload_Too_Large);
         end if;
      end loop;
      return (Valid => True, Value => Value);
   end Body_Length_Of;

   ----------------
   -- Parse_Head --
   ----------------

   function Parse_Head (Request : String) return Request_Head is
      Head_End             : Natural := 0; --  the last byte of the blank line
      Line_End             : Positive;
      First_Space          : Positive;
      Second_Space         : Positive;
      Question             : Positive;
      Query                : Span := (1, 0); --  after '?', empty when there is none
      Line_First           : Positive;
      Keep_Alive_Requested : Boolean := False;
      Http_1_0             : Boolean;
      Verb                 : Method;
      Result               : Request_Head (Complete);
   begin
      if Request'Length >= 4 then
         for Position in Request'First .. Request'Last - 3 loop
            if Request (Position .. Position + 3) = CRLF & CRLF then
               Head_End := Position + 3;
               exit;
            end if;
         end loop;
      end if;

      if Head_End = 0 then
         return (if Request'Length > Max_Head_Length then (Outcome => Invalid, Status => Bad_Request)
                 else (Outcome => Incomplete));
      end if;
      pragma Assert (Head_End in Request'First + 3 .. Request'Last);

      --  request line: METHOD SP target SP version
      Line_End    := Find (Request, ASCII.CR, Request'First, Head_End);
      First_Space := Find (Request, ' ', Request'First, Line_End);
      if First_Space >= Line_End then
         return (Outcome => Invalid, Status => Bad_Request);
      end if;

      Second_Space := Find (Request, ' ', First_Space + 1, Line_End);
      if Second_Space >= Line_End then
         return (Outcome => Invalid, Status => Bad_Request);
      end if;

      Question := Find (Request, '?', First_Space + 1, Second_Space);
      Http_1_0 := Request (Second_Space + 1 .. Line_End - 1) = "HTTP/1.0";

      declare
         Verb_Last : constant Natural := First_Space - 1;
         Verb_Text : String renames Request (Request'First .. Verb_Last);
      begin
         Verb := (if Verb_Text = "GET" then Get elsif Verb_Text = "POST" then Post
                  elsif Verb_Text = "PUT" then Put elsif Verb_Text = "DELETE" then Delete
                  else Other);
      end;

      if Question < Second_Space then
         Query := (Question + 1, Second_Space - 1);
      end if;

      Result := (Outcome           => Complete,
                 Verb              => Verb,
                 Path              => (First_Space + 1, Question - 1),
                 Query             => Query,
                 Has_Authorization => False,
                 Authorization     => (1, 0),
                 Head_Length       => Head_End - Request'First + 1,
                 Body_Length       => 0,
                 Keep_Alive        => True);

      --  header lines, up to the blank one
      Line_First := Line_End + 2;
      while Line_First < Head_End - 1 loop

         pragma Loop_Invariant (Line_First > Request'First
                                and then Result.Head_Length <= Request'Length
                                and then Within (Result.Path, Request)
                                and then Within (Result.Query, Request)
                                and then Within (Result.Authorization, Request));
         pragma Loop_Variant (Increases => Line_First);

         declare
            Next_Line_End : constant Positive := Find (Request, ASCII.CR, Line_First, Head_End);
            Colon         : constant Positive := Find (Request, ':', Line_First, Next_Line_End);
            Value_First   : Positive;
            Value_Last    : Natural;
         begin

            if Colon < Next_Line_End then
               Value_First := Colon + 1;
               Value_Last  := Next_Line_End - 1;
               while Value_First <= Value_Last and then Request (Value_First) in ' ' | ASCII.HT loop
                  pragma Loop_Invariant (Value_First in Colon + 1 .. Value_Last);
                  pragma Loop_Variant (Increases => Value_First);
                  Value_First := Value_First + 1;
               end loop;

               while Value_Last >= Value_First and then Request (Value_Last) in ' ' | ASCII.HT loop
                  pragma Loop_Invariant (Value_Last in Value_First .. Next_Line_End - 1);
                  pragma Loop_Variant (Decreases => Value_Last);
                  Value_Last := Value_Last - 1;
               end loop;
               
               declare
                  Name_First : constant Positive := Line_First;
                  Name_Last  : constant Natural := Colon - 1;
                  Text_First : constant Positive := Value_First;
                  Text_Last  : constant Natural := Value_Last;
                  Name       : String renames Request (Name_First .. Name_Last);
                  Value      : String renames Request (Text_First .. Text_Last);
               begin
                  if Same_Name (Name, "content-length") then
                     declare
                        Field : constant Length_Field := Body_Length_Of (Value);
                     begin
                        if not Field.Valid then
                           return (Outcome => Invalid, Status => Field.Status);
                        end if;
                        Result.Body_Length := Field.Value;
                     end;
                  elsif Same_Name (Name, "authorization") then
                     Result.Has_Authorization := True;
                     Result.Authorization     := (Value_First, Value_Last);
                  elsif Same_Name (Name, "connection") then
                     if Contains_Token (Value, "close") then
                        Result.Keep_Alive := False;
                     elsif Contains_Token (Value, "keep-alive") then
                        Keep_Alive_Requested := True;
                     end if;
                  elsif Same_Name (Name, "transfer-encoding") then
                     return (Outcome => Invalid, Status => Bad_Request);
                  end if;
               end;
            end if;

            Line_First := Next_Line_End + 2;
         end;
      end loop;

      if Http_1_0 and then not Keep_Alive_Requested then
         Result.Keep_Alive := False;
      end if;
      return Result;
   end Parse_Head;

end Http;
