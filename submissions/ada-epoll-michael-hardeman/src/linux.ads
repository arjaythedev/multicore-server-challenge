--  Thin bindings to the Linux system calls the server uses (x86-64), through glibc.
--  Kernel constants keep their C names so they can be looked up in the man pages.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings;
with System;
with Model;

package Linux is

   type File_Descriptor is new int;
   No_Descriptor : constant File_Descriptor := -1;

   type Error_Code is new int;
   EINTR   : constant Error_Code := 4;
   EAGAIN  : constant Error_Code := 11;
   ENOMEM  : constant Error_Code := 12;
   ENFILE  : constant Error_Code := 23;
   EMFILE  : constant Error_Code := 24;
   ENOBUFS : constant Error_Code := 105;

   --  The calling thread's errno.
   function Last_Error return Error_Code;

   type IPv4_Address is new Unsigned_32;   --  host byte order
   Any_Address : constant IPv4_Address := 0;
   Loopback    : constant IPv4_Address := 16#7F00_0001#;

   type Port_Number is range 0 .. 65_535;

   ---------------------------------------------------------------------------------------------------------------
   --  sockets

   AF_INET       : constant := 2;
   SOCK_STREAM   : constant := 1;
   SOCK_NONBLOCK : constant := 8#4000#;
   SOCK_CLOEXEC  : constant := 8#2000000#;
   SOL_SOCKET    : constant := 1;
   SO_REUSEADDR  : constant := 2;
   SO_REUSEPORT  : constant := 15;
   IPPROTO_TCP   : constant := 6;
   TCP_NODELAY   : constant := 1;
   MSG_NOSIGNAL  : constant := 16#4000#;

   type Socket_Address is record
      Family  : Unsigned_16;
      Port    : Unsigned_16;    --  network byte order
      Address : Unsigned_32;    --  network byte order
      Padding : Unsigned_64;
   end record with Convention => C;

   function To_Socket_Address (Address : IPv4_Address; Port : Port_Number) return Socket_Address;

   --  A non-blocking listening socket with SO_REUSEPORT; No_Descriptor on failure.
   function Open_Listener (Address : IPv4_Address; Port : Port_Number) return File_Descriptor;
   --  A blocking, connected TCP socket with TCP_NODELAY; No_Descriptor on failure.
   function Connect_To (Address : IPv4_Address; Port : Port_Number) return File_Descriptor;
   procedure Set_No_Delay (Socket : File_Descriptor);

   function Accept_Connection (Listener : File_Descriptor) return File_Descriptor;   --  non-blocking
   procedure Close (Descriptor : File_Descriptor);

   --  Byte counts, or -1 with Last_Error set.
   function Read (Descriptor : File_Descriptor; Into : System.Address; Count : size_t) return long
      with Import, Convention => C, External_Name => "read";
   function Write (Descriptor : File_Descriptor; From : System.Address; Count : size_t) return long
      with Import, Convention => C, External_Name => "write";
   function Send (Socket : File_Descriptor; From : System.Address; Count : size_t; Flags : int) return long
      with Import, Convention => C, External_Name => "send";

   type IO_Vector is record
      Base   : System.Address;
      Length : size_t;
   end record with Convention => C;
   type IO_Vector_Array is array (Positive range <>) of IO_Vector with Convention => C;

   function Write_Vector (Descriptor : File_Descriptor; Vectors : System.Address; Count : int) return long
      with Import, Convention => C, External_Name => "writev";

   ---------------------------------------------------------------------------------------------------------------
   --  epoll and eventfd

   type Event_Mask is new Unsigned_32;
   EPOLLIN    : constant Event_Mask := 16#001#;
   EPOLLOUT   : constant Event_Mask := 16#004#;
   EPOLLERR   : constant Event_Mask := 16#008#;
   EPOLLHUP   : constant Event_Mask := 16#010#;
   EPOLLRDHUP : constant Event_Mask := 16#2000#;
   EPOLLET    : constant Event_Mask := 16#8000_0000#;

   type Epoll_Event is record
      Events : Event_Mask;
      Data   : Unsigned_64;
   end record with Convention => C;
   for Epoll_Event use record
      Events at 0 range 0 .. 31;
      Data   at 4 range 0 .. 63;
   end record;
   for Epoll_Event'Size use 96;   --  packed on x86-64
   type Epoll_Event_Array is array (Positive range <>) of Epoll_Event with Convention => C;

   function Create_Epoll return File_Descriptor;
   procedure Watch (Epoll, Descriptor : File_Descriptor; Events : Event_Mask);
   procedure Unwatch (Epoll, Descriptor : File_Descriptor);
   --  Number of events written to Into; Timeout_Milliseconds < 0 waits forever.
   function Wait (Epoll : File_Descriptor; Into : in out Epoll_Event_Array; Timeout_Milliseconds : Integer)
      return Natural;

   function Create_Event_Counter return File_Descriptor;   --  non-blocking eventfd
   procedure Signal (Counter : File_Descriptor);
   procedure Drain (Counter : File_Descriptor);

   ---------------------------------------------------------------------------------------------------------------
   --  process, time, randomness

   subtype Unix_Seconds is Model.Unix_Seconds;
   type Milliseconds is new Long_Long_Integer;

   function Now return Unix_Seconds;                   --  CLOCK_REALTIME_COARSE
   function Monotonic_Clock return Milliseconds;       --  CLOCK_MONOTONIC_COARSE

   procedure Random_Bytes (Into : out String);         --  getrandom
   procedure Ignore_Broken_Pipes;                      --  SIGPIPE ignored
   function Raise_Open_File_Limit return Natural;      --  soft limit up to the hard one; returns the new limit
   procedure Set_Nice (Value : Integer);               --  calling thread
   procedure Use_Batch_Scheduling;                     --  SCHED_BATCH for the calling thread

   --  Give the calling thread its own copy of the descriptor table. RLIMIT_NOFILE bounds the descriptor numbers of
   --  each table, so threads with their own tables can hold that many descriptors each. False if refused.
   function Unshare_Descriptors return Boolean;

   --  An environment variable's value; "" when unset.
   function Environment (Name : String) return String;

private

   function C_Getenv (Name : char_array) return Interfaces.C.Strings.chars_ptr
      with Import, Convention => C, External_Name => "getenv";

end Linux;
