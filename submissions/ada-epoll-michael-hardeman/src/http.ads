--  HTTP/1.1 request heads and the fixed parts of responses. Proved free of run-time errors (SPARK silver): the
--  parser cannot raise or read outside the request on any input, and every span it returns lies inside it.
package Http with SPARK_Mode is

   type Status_Code is range 100 .. 599;
   OK                    : constant Status_Code := 200;
   Created               : constant Status_Code := 201;
   No_Content            : constant Status_Code := 204;
   Bad_Request           : constant Status_Code := 400;
   Unauthorized          : constant Status_Code := 401;
   Forbidden             : constant Status_Code := 403;
   Not_Found             : constant Status_Code := 404;
   Payload_Too_Large     : constant Status_Code := 413;
   Unprocessable_Content : constant Status_Code := 422;
   Internal_Server_Error : constant Status_Code := 500;

   --  "HTTP/1.1 404 Not Found" and its line break.
   function Status_Line (Status : Status_Code) return String
   with Post => Status_Line'Result'First = 1 and then Status_Line'Result'Length <= 64;

   --  The API's error body: {"errors":{"body":["not found"]}}.
   function Error_Body (Status : Status_Code) return String
   with Post => Error_Body'Result'Length <= 64;

   CRLF : constant String := ASCII.CR & ASCII.LF;

   Max_Head_Length : constant := 16_384;
   Max_Body_Length : constant := 1_048_576;

   type Method is (Get, Post, Put, Delete, Other);

   --  A range of the request bytes; First > Last when empty.
   type Span is record
      First : Positive := 1;
      Last  : Natural := 0;
   end record;

   function Length (Of_Span : Span) return Natural is
     (if Of_Span.Last < Of_Span.First then 0 else Of_Span.Last - Of_Span.First + 1);

   --  Empty, or inside Text.
   function Within (Item : Span; Text : String) return Boolean is
     (Length (Item) = 0 or else (Item.First >= Text'First and then Item.Last <= Text'Last));

   type Parse_Outcome is (Complete, Incomplete, Invalid);

   type Request_Head (Outcome : Parse_Outcome := Incomplete) is record
      case Outcome is
         when Complete =>
            Verb              : Method;
            Path              : Span;      --  the target before '?'
            Query             : Span;      --  after '?', empty when there is none
            Has_Authorization : Boolean;
            Authorization     : Span;      --  the header value, trimmed
            Head_Length       : Positive;  --  through the blank line
            Body_Length       : Natural;
            Keep_Alive        : Boolean;
         when Incomplete =>
            null;                          --  the blank line has not arrived yet
         when Invalid =>
            Status : Status_Code;          --  answer it, then close
      end case;
   end record;

   --  Parse the head at the start of Request. Bodies need a Content-Length; chunked bodies are refused.
   function Parse_Head (Request : String) return Request_Head
   with
     Pre  => Request'Last < Positive'Last - 4,
     Post =>
       (if Parse_Head'Result.Outcome = Complete then
          Parse_Head'Result.Head_Length <= Request'Length
          and then Within (Parse_Head'Result.Path, Request)
          and then Within (Parse_Head'Result.Query, Request)
          and then Within (Parse_Head'Result.Authorization, Request));

end Http;
