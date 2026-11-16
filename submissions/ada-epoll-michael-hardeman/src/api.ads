--  Routing and validation, on the reactor: everything that can be answered without Postgres is answered here
--  (401s, 404s for impossible keys, 422s); the rest becomes a job.
--
--  Proved free of run-time errors (SPARK silver). A request is validated completely before its job is
--  allocated, so a rejection has nothing to clean up.
with Http;
with Jobs;
with Json;
with Model;

package Api with SPARK_Mode is

   use type Http.Parse_Outcome;
   use type Jobs.Job_Access;

   type Routing (Accepted : Boolean := False) is record
      case Accepted is
         when True  => Work : Jobs.Job_Access;    --  to submit, once its reply target is set
         when False => Status : Http.Status_Code; --  answer with the error body at once
      end case;
   end record;

   --  Request holds the whole request, head and body; Document is scratch space for its JSON body.
   procedure Route
     (Request  : String;
      Head     : Http.Request_Head;
      Now      : Model.Unix_Seconds;
      Document : in out Json.Document;
      Result   : out Routing)
      with Pre => Request'First = 1 
                  and then Request'Last < Positive'Last
                  and then Head.Outcome = Http.Complete
                  and then Head.Head_Length <= Request'Length
                  and then Head.Body_Length = Request'Length - Head.Head_Length
                  and then Http.Within (Head.Path, Request)
                  and then Http.Within (Head.Query, Request)
                  and then Http.Within (Head.Authorization, Request)
                  and then Document.Text_Capacity < Positive'Last
                  and then not Result'Constrained,
           Post => (if Result.Accepted then Result.Work /= null);

end Api;
