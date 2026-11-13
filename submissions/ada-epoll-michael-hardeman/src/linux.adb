with System.Storage_Elements;

package body Linux is

   type Error_Code_Access is access all Error_Code with Convention => C;
   function Errno_Location return Error_Code_Access
      with Import, Convention => C, External_Name => "__errno_location";

   ----------------
   -- Last_Error --
   ----------------

   function Last_Error return Error_Code is (Errno_Location.all);

   ---------------------------------------------------------------------------------------------------------------
   --  imports used only here

   function C_Socket (Domain, Kind, Protocol : int) return File_Descriptor
      with Import, Convention => C, External_Name => "socket";
   function C_Setsockopt (Socket : File_Descriptor; Level, Name : int; 
                          Value : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "setsockopt";
   function C_Bind (Socket : File_Descriptor; Address : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "bind";
   function C_Listen (Socket : File_Descriptor; Backlog : int) return int
      with Import, Convention => C, External_Name => "listen";
   function C_Accept4 (Socket : File_Descriptor; Address, Length : System.Address; Flags : int) return File_Descriptor
      with Import, Convention => C, External_Name => "accept4";
   function C_Connect (Socket : File_Descriptor; Address : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "connect";
   function C_Close (Descriptor : File_Descriptor) return int
      with Import, Convention => C, External_Name => "close";
   function C_Epoll_Create1 (Flags : int) return File_Descriptor
      with Import, Convention => C, External_Name => "epoll_create1";
   function C_Epoll_Ctl (Epoll : File_Descriptor; Operation : int; Descriptor : File_Descriptor;
                         Event : System.Address) return int
      with Import, Convention => C, External_Name => "epoll_ctl";
   function C_Epoll_Wait (Epoll : File_Descriptor; Events : System.Address; Max_Events, Timeout : int) return int
      with Import, Convention => C, External_Name => "epoll_wait";
   function C_Eventfd (Initial : unsigned; Flags : int) return File_Descriptor
      with Import, Convention => C, External_Name => "eventfd";

   type Resource_Limit is record
      Current, Maximum : Unsigned_64;
   end record with Convention => C;
   function C_Getrlimit (Resource : int; Limit : access Resource_Limit) return int
      with Import, Convention => C, External_Name => "getrlimit";
   function C_Setrlimit (Resource : int; Limit : access Resource_Limit) return int
      with Import, Convention => C, External_Name => "setrlimit";

   type Time_Spec is record
      Seconds     : long;
      Nanoseconds : long;
   end record with Convention => C;
   function C_Clock_Gettime (Clock : int; Time : access Time_Spec) return int
      with Import, Convention => C, External_Name => "clock_gettime";

   function C_Getrandom (Into : System.Address; Length : size_t; Flags : unsigned) return long
      with Import, Convention => C, External_Name => "getrandom";
   function C_Setpriority (Which, Who, Priority : int) return int
      with Import, Convention => C, External_Name => "setpriority";
   function C_Sched_Setscheduler (Process, Policy : int; Parameters : System.Address) return int
      with Import, Convention => C, External_Name => "sched_setscheduler";
   function C_Unshare (Flags : int) return int
      with Import, Convention => C, External_Name => "unshare";
   function C_Signal (Signal_Number : int; Handler : System.Address) return System.Address
      with Import, Convention => C, External_Name => "signal";

   EPOLL_CLOEXEC          : constant := 8#2000000#;
   EPOLL_CTL_ADD          : constant := 1;
   EPOLL_CTL_DEL          : constant := 2;
   EFD_NONBLOCK           : constant := 8#4000#;
   EFD_CLOEXEC            : constant := 8#2000000#;
   RLIMIT_NOFILE          : constant := 7;
   CLOCK_REALTIME_COARSE  : constant := 5;
   CLOCK_MONOTONIC_COARSE : constant := 6;
   SCHED_BATCH            : constant := 3;
   SIGPIPE                : constant := 13;
   SIG_IGN                : constant := 1;

   ---------------------------------------------------------------------------------------------------------------
   --  addresses and sockets

   ----------------
   -- Swap_Bytes --
   ----------------

   function Swap_Bytes (Value : Unsigned_32) return Unsigned_32 is
     (Shift_Left (Value and 255, 24) or Shift_Left (Shift_Right (Value, 8) and 255, 16)
      or Shift_Left (Shift_Right (Value, 16) and 255, 8) or Shift_Right (Value, 24));

   -----------------------
   -- To_Socket_Address --
   -----------------------

   function To_Socket_Address (Address : IPv4_Address; Port : Port_Number) return Socket_Address is
     (Family  => AF_INET,
      Port    => Rotate_Left (Unsigned_16 (Port), 8),
      Address => Swap_Bytes (Unsigned_32 (Address)),
      Padding => 0);

   ----------------
   -- Set_Option --
   ----------------

   procedure Set_Option (Socket : File_Descriptor; Level, Name : int) is
      Enabled : aliased int := 1;
   begin
      if C_Setsockopt (Socket, Level, Name, Enabled'Address, unsigned (int'Size / 8)) /= 0 then
         null;   --  an option the kernel refuses only costs performance
      end if;
   end Set_Option;

   ------------------
   -- Set_No_Delay --
   ------------------

   procedure Set_No_Delay (Socket : File_Descriptor) is begin
      Set_Option (Socket, IPPROTO_TCP, TCP_NODELAY);
   end Set_No_Delay;

   -------------------
   -- Open_Listener --
   -------------------

   function Open_Listener (Address : IPv4_Address; Port : Port_Number) return File_Descriptor is
      Socket : constant File_Descriptor := C_Socket (AF_INET, SOCK_STREAM + SOCK_NONBLOCK + SOCK_CLOEXEC, 0);
      Where  : aliased Socket_Address := To_Socket_Address (Address, Port);
   begin
      if Socket = No_Descriptor then
         return No_Descriptor;
      end if;

      Set_Option (Socket, SOL_SOCKET, SO_REUSEADDR);
      Set_Option (Socket, SOL_SOCKET, SO_REUSEPORT);
      if C_Bind (Socket, Where'Address, Socket_Address'Size / 8) /= 0 or else C_Listen (Socket, 65_535) /= 0 then
         Close (Socket);
         return No_Descriptor;
      end if;
      return Socket;
   end Open_Listener;

   ----------------
   -- Connect_To --
   ----------------

   function Connect_To (Address : IPv4_Address; Port : Port_Number) return File_Descriptor is
      Socket : constant File_Descriptor := C_Socket (AF_INET, SOCK_STREAM + SOCK_CLOEXEC, 0);
      Where  : aliased Socket_Address := To_Socket_Address (Address, Port);
   begin
      if Socket = No_Descriptor then
         return No_Descriptor;
      end if;

      if C_Connect (Socket, Where'Address, Socket_Address'Size / 8) /= 0 then
         Close (Socket);
         return No_Descriptor;
      end if;

      Set_No_Delay (Socket);
      return Socket;
   end Connect_To;

   -----------------------
   -- Accept_Connection --
   -----------------------

   function Accept_Connection (Listener : File_Descriptor) return File_Descriptor is
     (C_Accept4 (Listener, System.Null_Address, System.Null_Address, SOCK_NONBLOCK + SOCK_CLOEXEC));

   -----------
   -- Close --
   -----------

   procedure Close (Descriptor : File_Descriptor) is begin
      if C_Close (Descriptor) /= 0 then
         null;   --  the descriptor is released even when close reports an error
      end if;
   end Close;

   ---------------------------------------------------------------------------------------------------------------
   --  epoll and eventfd

   ------------------
   -- Create_Epoll --
   ------------------

   function Create_Epoll return File_Descriptor is (C_Epoll_Create1 (EPOLL_CLOEXEC));

   -----------
   -- Watch --
   -----------

   procedure Watch (Epoll, Descriptor : File_Descriptor; Events : Event_Mask) is
      Event : aliased Epoll_Event := (Events => Events, Data => Unsigned_64 (Descriptor));
   begin
      if C_Epoll_Ctl (Epoll, EPOLL_CTL_ADD, Descriptor, Event'Address) /= 0 then
         raise Program_Error with "epoll_ctl add failed";
      end if;
   end Watch;

   -------------
   -- Unwatch --
   -------------

   procedure Unwatch (Epoll, Descriptor : File_Descriptor) is begin
      if C_Epoll_Ctl (Epoll, EPOLL_CTL_DEL, Descriptor, System.Null_Address) /= 0 then
         null;   --  not watched: nothing to undo
      end if;
   end Unwatch;

   ----------
   -- Wait --
   ----------

   function Wait (Epoll : File_Descriptor; Into : in out Epoll_Event_Array; Timeout_Milliseconds : Integer)
                  return Natural
   is
      Count : constant int := C_Epoll_Wait (Epoll, Into'Address, Into'Length, int (Timeout_Milliseconds));
   begin
      return (if Count < 0 then 0 else Natural (Count));   --  EINTR: an empty round
   end Wait;

   --------------------------
   -- Create_Event_Counter --
   --------------------------

   function Create_Event_Counter return File_Descriptor is (C_Eventfd (0, EFD_NONBLOCK + EFD_CLOEXEC));

   ------------
   -- Signal --
   ------------

   procedure Signal (Counter : File_Descriptor) is
      One     : aliased Unsigned_64 := 1;
      Written : long;
   begin
      Written := Write (Counter, One'Address, 8);
      pragma Unreferenced (Written);   --  a full counter is already signalled
   end Signal;

   -----------
   -- Drain --
   -----------

   procedure Drain (Counter : File_Descriptor) is
      Value : aliased Unsigned_64;
      Got   : long;
   begin
      Got := Read (Counter, Value'Address, 8);
      pragma Unreferenced (Got);   --  EAGAIN: already drained
   end Drain;

   ---------------------------------------------------------------------------------------------------------------
   --  process, time, randomness

   ---------
   -- Now --
   ---------

   function Now return Unix_Seconds is
      Time : aliased Time_Spec;
   begin
      if C_Clock_Gettime (CLOCK_REALTIME_COARSE, Time'Access) /= 0 then
         raise Program_Error with "clock_gettime failed";
      end if;
      return Unix_Seconds (Time.Seconds);
   end Now;

   ---------------------
   -- Monotonic_Clock --
   ---------------------

   function Monotonic_Clock return Milliseconds is
      Time : aliased Time_Spec;
   begin
      if C_Clock_Gettime (CLOCK_MONOTONIC_COARSE, Time'Access) /= 0 then
         raise Program_Error with "clock_gettime failed";
      end if;
      return Milliseconds (Time.Seconds) * 1000 + Milliseconds (Time.Nanoseconds) / 1_000_000;
   end Monotonic_Clock;

   ------------------
   -- Random_Bytes --
   ------------------

   procedure Random_Bytes (Into : out String) is
      Got : long;
   begin
      Into := [others => ASCII.NUL];
      if Into'Length = 0 then
         return;
      end if;

      loop
         Got := C_Getrandom (Into'Address, size_t (Into'Length), 0);
         exit when Got = long (Into'Length);
         if Got < 0 and then Last_Error /= EINTR then
            raise Program_Error with "getrandom failed";
         end if;
      end loop;
   end Random_Bytes;

   -------------------------
   -- Ignore_Broken_Pipes --
   -------------------------

   procedure Ignore_Broken_Pipes is
      Previous : System.Address;
   begin
      Previous := C_Signal (SIGPIPE, System.Storage_Elements.To_Address (SIG_IGN));
      pragma Unreferenced (Previous);
   end Ignore_Broken_Pipes;

   ---------------------------
   -- Raise_Open_File_Limit --
   ---------------------------

   function Raise_Open_File_Limit return Natural is
      Limit : aliased Resource_Limit;
   begin
      if C_Getrlimit (RLIMIT_NOFILE, Limit'Access) /= 0 then
         return 1024;
      end if;

      if Limit.Current < Limit.Maximum then
         Limit.Current := Limit.Maximum;
         if C_Setrlimit (RLIMIT_NOFILE, Limit'Access) /= 0 or else C_Getrlimit (RLIMIT_NOFILE, Limit'Access) /= 0
         then
            null;   --  keep whatever the soft limit is
         end if;
      end if;

      return Natural (Unsigned_64'Min (Limit.Current, 4_000_000));
   end Raise_Open_File_Limit;

   --------------
   -- Set_Nice --
   --------------

   procedure Set_Nice (Value : Integer) is begin
      if C_Setpriority (0, 0, int (Value)) /= 0 then
         null;   --  a priority hint only
      end if;
   end Set_Nice;

   --------------------------
   -- Use_Batch_Scheduling --
   --------------------------

   procedure Use_Batch_Scheduling is
      Parameters : aliased int := 0;   --  struct sched_param { int sched_priority; }
   begin
      if C_Sched_Setscheduler (0, SCHED_BATCH, Parameters'Address) /= 0 then
         null;   --  a scheduling hint only
      end if;
   end Use_Batch_Scheduling;

   -------------------------
   -- Unshare_Descriptors --
   -------------------------

   function Unshare_Descriptors return Boolean is
      CLONE_FILES : constant := 16#400#;
   begin
      return C_Unshare (CLONE_FILES) = 0;
   end Unshare_Descriptors;

   -----------------
   -- Environment --
   -----------------

   function Environment (Name : String) return String is
      use type Interfaces.C.Strings.chars_ptr;
      Value : constant Interfaces.C.Strings.chars_ptr := C_Getenv (To_C (Name));
   begin
      return (if Value = Interfaces.C.Strings.Null_Ptr then "" else Interfaces.C.Strings.Value (Value));
   end Environment;

end Linux;
