--  JSON for the API's objects, written straight from Postgres rows.
--
--  Proved free of run-time errors (SPARK silver).
with Buffers; use Buffers;
with Postgres; use Postgres;

package Render with SPARK_Mode is

   --  {"user": {...}} from (id, username, email, bio, image) at columns First .. First + 4 of Row.
   procedure User (Into  : in out Buffer;
                   From  : Connection;
                   Rows  : Statement_Result;
                   Token : String;
                   Row   : Positive := 1;
                   First : Positive := 1)
      with Pre => Valid (Into) and then First <= Positive'Last - 4, Post => Valid (Into);

   --  {"profile": {...}} from username, bio and image at columns First .. First + 2 of Row.
   procedure Profile (Into      : in out Buffer;
                      From      : Connection;
                      Rows      : Statement_Result;
                      First     : Positive;
                      Following : Boolean;
                      Row       : Positive := 1)
      with Pre => Valid (Into) and then First <= Positive'Last - 2, Post => Valid (Into);

   --  A comment from (id, body, created_at, updated_at, username, bio, image).
   procedure Comment (Into      : in out Buffer;
                      From      : Connection;
                      Rows      : Statement_Result;
                      Row       : Positive;
                      Following : Boolean)
      with Pre => Valid (Into), Post => Valid (Into);

end Render;
