--  The system calls the proved code makes, with contracts the proofs rely on. The bodies are thin glibc calls
--  outside SPARK; each contract states what the kernel guarantees (read and send never report more bytes than
--  the buffer holds), and the kernel's state is one external abstract state, synchronized (every task may use
--  it: the kernel serializes what it must).
with Linux; use Linux;

package Socket_IO
  with
    SPARK_Mode,
    Abstract_State => ((Kernel with Synchronous, External), Start_Up),
    Initializes    => (Kernel, Start_Up)
is

   --  A read into Into (Into'First .. Into'First + Count - 1). Count is 0 at end of stream, and -1 on an error,
   --  which Error then names (otherwise it is 0).
   procedure Receive (Socket : File_Descriptor; Into : in out String; Count : out Integer; Error : out Error_Code)
      with Global => (In_Out => Kernel),
           Pre    => Into'Length > 0,
           Post   => Count in -1 .. Into'Length and then (if Count >= 0 then Error = 0);

   --  A send of a prefix of From, without SIGPIPE: Count bytes, or -1 with Error.
   procedure Send (Socket : File_Descriptor; From : String; Count : out Integer; Error : out Error_Code)
      with Global => (In_Out => Kernel),
           Pre    => From'Length > 0,
           Post   => Count in -1 .. From'Length and then (if Count >= 0 then Error = 0);

   --  A blocking TCP connection with TCP_NODELAY, or No_Descriptor.
   procedure Connect (Address : IPv4_Address; Port : Port_Number; Socket : out File_Descriptor)
      with Global => (In_Out => Kernel);

   procedure Close (Socket : File_Descriptor) with Global => (In_Out => Kernel);

   procedure Random_Bytes (Into : out String) with Global => (In_Out => Kernel);

   --  One writev of Head then Content, without SIGPIPE: Count bytes, or -1 with Error.
   procedure Send_Pair
     (Socket : File_Descriptor; Head, Content : String; Count : out Integer; Error : out Error_Code)
      with Global => (In_Out => Kernel),
           Pre    => Head'Length > 0 and then Content'Length <= Integer'Last - Head'Length,
           Post   => Count in -1 .. Head'Length + Content'Length and then (if Count >= 0 then Error = 0);

   --  A non-blocking accept: the new connection, or No_Descriptor with Error.
   procedure Accept_Client (Listener : File_Descriptor; Socket : out File_Descriptor; Error : out Error_Code)
      with Global => (In_Out => Kernel);

   procedure Set_No_Delay (Socket : File_Descriptor) with Global => (In_Out => Kernel);

   procedure Watch (Epoll, Descriptor : File_Descriptor; Events : Event_Mask) with Global => (In_Out => Kernel);
   procedure Unwatch (Epoll, Descriptor : File_Descriptor) with Global => (In_Out => Kernel);

   --  Reset an eventfd counter.
   procedure Drain (Counter : File_Descriptor) with Global => (In_Out => Kernel);

   --  CLOCK_MONOTONIC_COARSE.
   procedure Read_Monotonic (Now : out Milliseconds)
      with Global => (In_Out => Kernel), Post => Now in 0 .. 2 ** 62;

   ---------------------------------------------------------------------------------------------------------------
   --  for the tasks

   --  A non-blocking SO_REUSEPORT listener, or No_Descriptor.
   procedure Open_Listener (Address : IPv4_Address; Port : Port_Number; Listener : out File_Descriptor)
      with Global => (In_Out => Kernel);

   procedure Create_Epoll (Epoll : out File_Descriptor) with Global => (In_Out => Kernel);

   --  epoll_wait into Into (1 .. Count); Timeout_Milliseconds < 0 waits forever. Count is 0 on EINTR.
   procedure Wait
     (Epoll : File_Descriptor; Into : in out Epoll_Event_Array; Timeout_Milliseconds : Integer; Count : out Natural)
      with Global => (In_Out => Kernel), Pre => Into'First = 1 and then Into'Length > 0, Post => Count <= Into'Last;

   --  A non-blocking eventfd, or No_Descriptor; Signal adds one to it.
   procedure Create_Event_Counter (Counter : out File_Descriptor) with Global => (In_Out => Kernel);
   procedure Signal (Counter : File_Descriptor) with Global => (In_Out => Kernel);

   --  The calling thread gets its own copy of the descriptor table (False if refused).
   procedure Unshare_Descriptors (Done : out Boolean) with Global => (In_Out => Kernel);

   --  The soft RLIMIT_NOFILE raised to the hard one; Limit is the limit now.
   procedure Raise_Open_File_Limit (Limit : out Natural) with Global => (In_Out => Kernel);

   --  Scheduling hints for the calling thread: SCHED_BATCH, and a nice value.
   procedure Use_Batch_Scheduling with Global => (In_Out => Kernel);
   procedure Set_Nice (Value : Integer) with Global => (In_Out => Kernel);

   --  SIGPIPE ignored, process-wide.
   procedure Ignore_Broken_Pipes with Global => (In_Out => Kernel);

   --  The process exits with Code (start-up failures only).
   procedure Stop (Code : Integer) with Global => (In_Out => Kernel);

   --  The calling thread sleeps.
   procedure Sleep (Duration_Milliseconds : Milliseconds) with Global => (In_Out => Kernel);

   --  What the process is given as it starts (Start_Up), fixed afterwards so it is not volatile state:

   --  an environment variable's value ("" when unset, cut at 64 KiB);
   subtype Environment_Text is String
      with Dynamic_Predicate => Environment_Text'First = 1 and then Environment_Text'Length <= 65_536;
   function Environment (Name : String) return Environment_Text with Global => Start_Up;

   --  the eventfd of each reactor, made as this package elaborates, before any task is activated, so every
   --  task's descriptor table has them (No_Descriptor if eventfd failed).
   Max_Counters : constant := 64;
   function Event_Counter (Index : Natural) return File_Descriptor
      with Global => Start_Up, Pre => Index < Max_Counters;

end Socket_IO;
