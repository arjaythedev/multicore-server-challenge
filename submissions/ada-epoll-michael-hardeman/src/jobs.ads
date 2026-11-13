--  A job is one API request on its way through the server: the reactor that parsed it builds it, it visits
--  the read lanes, the write lane and the hashers as its phase says, and goes back to its reactor with a
--  response. The queues between those stages are in Job_Queues.
with Buffers; use Buffers;
with Http;
with Linux;
with Model; use Model;

package Jobs with SPARK_Mode is

   use type Linux.File_Descriptor;

   type Endpoint is
     (Register, Login, Current_User, Update_User,
      Get_Profile, Follow, Unfollow,
      List_Articles, Feed,
      Get_Article, Create_Article, Update_Article, Delete_Article, Favorite, Unfavorite,
      List_Comments, Add_Comment, Delete_Comment,
      List_Tags);

   subtype Account_Endpoint is Endpoint range      Register .. Update_User;
   subtype Profile_Endpoint is Endpoint range   Get_Profile .. Unfollow;
   subtype Listing_Endpoint is Endpoint range List_Articles .. Feed;
   subtype Article_Endpoint is Endpoint range   Get_Article .. Delete_Comment;

   --  Where a job goes next. Reading and Reading_Back go to the read lanes, Writing to the write lane, Hashing
   --  and Verifying to the hashers.
   type Phase is
     (Reading,       --  the endpoint's own query
      Hashing,       --  bcrypt a new password, then Writing
      Verifying,     --  check a login password against the hash Reading found
      Writing,       --  the endpoint's own statements
      Reading_Back); --  the article a write changed, rendered as the response

   --  null = absent from the request (or JSON null).
   type Account_Fields is record
      Username, Email, Password, Bio, Image : String_Access;
      Password_Hash : String_Access; --  from Hashing, or the stored hash Reading found for Verifying
      Token         : String_Access; --  the token the request presented
   end record;

   type Filter_Kind is (No_Filter, By_Tag, By_Author, By_Favoriter);

   type List_Filter (Kind : Filter_Kind := No_Filter) is record
      case Kind is
         when No_Filter => null;
         when others    => Value : String_Access; --  empty when it is text no row can hold
      end case;
   end record;

   type Article_Fields is record
      Title, Description, Text : String_Access;
      Tags                     : String_List_Access;
   end record;

   type Reactor_Id is range 0 .. 63;
   type Generation is mod 2 ** 32;   --  tells a reused descriptor's connections apart

   --  The connection a response goes back to.
   type Reply_Target is record
      Reactor    : Reactor_Id := 0;
      Client     : Linux.File_Descriptor := -1;
      Generation : Jobs.Generation := 0;
   end record;

   type Job;
   type Job_Access is access Job;

   type Job (Kind : Endpoint) is record
      Reply    : Reply_Target;
      Viewer   : User_Id          := Anonymous;
      Stage    : Phase            := Reading;
      Status   : Http.Status_Code := Http.OK;
      Response : Buffer;
      Queued   : Linux.Milliseconds := 0; --  when it last joined a queue
      Next     : Job_Access;              --  queue link
      --  Set by the reactor when the client hung up while the job was in flight: reads and password checks
      --  for it are skipped. Writes still run; the client may have sent one and gone.
      Abandoned : Boolean := False with Atomic;
      case Kind is
         when List_Tags        => null;
         when Listing_Endpoint => Filter       : List_Filter;
                                  Page         : Page_Window;
         when Account_Endpoint => Account      : Account_Fields;
         when Profile_Endpoint => Username     : String_Access;
         when Article_Endpoint => Slug         : String_Access;
                                  Article      : Article_Fields;
                                  Changed      : Article_Id := 0; --  for Reading_Back
                                  Comment      : Comment_Id := 0;
                                  Comment_Body : String_Access;
      end case;
   end record;

   type Job_List is array (Positive range <>) of Job_Access;

   --  A job on its own: the queue link must be cleared first.
   procedure Free (This : in out Job_Access)
      with Pre  => This = null or else This.Next = null,
           Post => This = null;

   --  Replace the response with the API's error body for Status.
   procedure Fail (This : in out Job; Status : Http.Status_Code) with Post => Valid (This.Response);

end Jobs;
