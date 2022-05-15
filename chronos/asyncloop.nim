#
#                     Chronos
#
#           (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}
from nativesockets import Port

import std/[tables, strutils, heapqueue, lists, options, deques]
import stew/results
import "."/[osdefs, osutils, timer]

export Port
export timer, results

#{.injectStmt: newGcInvariant().}

## AsyncDispatch
## *************
##
## This module implements asynchronous IO. This includes a dispatcher,
## a ``Future`` type implementation, and an ``async`` macro which allows
## asynchronous code to be written in a synchronous style with the ``await``
## keyword.
##
## The dispatcher acts as a kind of event loop. You must call ``poll`` on it
## (or a function which does so for you such as ``waitFor`` or ``runForever``)
## in order to poll for any outstanding events. The underlying implementation
## is based on epoll on Linux, IO Completion Ports on Windows and select on
## other operating systems.
##
## The ``poll`` function will not, on its own, return any events. Instead
## an appropriate ``Future`` object will be completed. A ``Future`` is a
## type which holds a value which is not yet available, but which *may* be
## available in the future. You can check whether a future is finished
## by using the ``finished`` function. When a future is finished it means that
## either the value that it holds is now available or it holds an error instead.
## The latter situation occurs when the operation to complete a future fails
## with an exception. You can distinguish between the two situations with the
## ``failed`` function.
##
## Future objects can also store a callback procedure which will be called
## automatically once the future completes.
##
## Futures therefore can be thought of as an implementation of the proactor
## pattern. In this
## pattern you make a request for an action, and once that action is fulfilled
## a future is completed with the result of that action. Requests can be
## made by calling the appropriate functions. For example: calling the ``recv``
## function will create a request for some data to be read from a socket. The
## future which the ``recv`` function returns will then complete once the
## requested amount of data is read **or** an exception occurs.
##
## Code to read some data from a socket may look something like this:
##
##   .. code-block::nim
##      var future = socket.recv(100)
##      future.addCallback(
##        proc () =
##          echo(future.read)
##      )
##
## All asynchronous functions returning a ``Future`` will not block. They
## will not however return immediately. An asynchronous function will have
## code which will be executed before an asynchronous request is made, in most
## cases this code sets up the request.
##
## In the above example, the ``recv`` function will return a brand new
## ``Future`` instance once the request for data to be read from the socket
## is made. This ``Future`` instance will complete once the requested amount
## of data is read, in this case it is 100 bytes. The second line sets a
## callback on this future which will be called once the future completes.
## All the callback does is write the data stored in the future to ``stdout``.
## The ``read`` function is used for this and it checks whether the future
## completes with an error for you (if it did it will simply raise the
## error), if there is no error however it returns the value of the future.
##
## Asynchronous procedures
## -----------------------
##
## Asynchronous procedures remove the pain of working with callbacks. They do
## this by allowing you to write asynchronous code the same way as you would
## write synchronous code.
##
## An asynchronous procedure is marked using the ``{.async.}`` pragma.
## When marking a procedure with the ``{.async.}`` pragma it must have a
## ``Future[T]`` return type or no return type at all. If you do not specify
## a return type then ``Future[void]`` is assumed.
##
## Inside asynchronous procedures ``await`` can be used to call any
## procedures which return a
## ``Future``; this includes asynchronous procedures. When a procedure is
## "awaited", the asynchronous procedure it is awaited in will
## suspend its execution
## until the awaited procedure's Future completes. At which point the
## asynchronous procedure will resume its execution. During the period
## when an asynchronous procedure is suspended other asynchronous procedures
## will be run by the dispatcher.
##
## The ``await`` call may be used in many contexts. It can be used on the right
## hand side of a variable declaration: ``var data = await socket.recv(100)``,
## in which case the variable will be set to the value of the future
## automatically. It can be used to await a ``Future`` object, and it can
## be used to await a procedure returning a ``Future[void]``:
## ``await socket.send("foobar")``.
##
## If an awaited future completes with an error, then ``await`` will re-raise
## this error. To avoid this, you can use the ``yield`` keyword instead of
## ``await``. The following section shows different ways that you can handle
## exceptions in async procs.
##
## Handling Exceptions
## ~~~~~~~~~~~~~~~~~~~
##
## The most reliable way to handle exceptions is to use ``yield`` on a future
## then check the future's ``failed`` property. For example:
##
##   .. code-block:: Nim
##     var future = sock.recv(100)
##     yield future
##     if future.failed:
##       # Handle exception
##
## The ``async`` procedures also offer limited support for the try statement.
##
##    .. code-block:: Nim
##      try:
##        let data = await sock.recv(100)
##        echo("Received ", data)
##      except:
##        # Handle exception
##
## Unfortunately the semantics of the try statement may not always be correct,
## and occasionally the compilation may fail altogether.
## As such it is better to use the former style when possible.
##
##
## Discarding futures
## ------------------
##
## Futures should **never** be discarded. This is because they may contain
## errors. If you do not care for the result of a Future then you should
## use the ``asyncCheck`` procedure instead of the ``discard`` keyword.
##
## Examples
## --------
##
## For examples take a look at the documentation for the modules implementing
## asynchronous IO. A good place to start is the
## `asyncnet module <asyncnet.html>`_.
##
## Limitations/Bugs
## ----------------
##
## * The effect system (``raises: []``) does not work with async procedures.
## * Can't await in a ``except`` body
## * Forward declarations for async procs are broken,
##   link includes workaround: https://github.com/nim-lang/Nim/issues/3182.

# TODO: Check if yielded future is nil and throw a more meaningful exception

const unixPlatform = defined(macosx) or defined(freebsd) or
                     defined(netbsd) or defined(openbsd) or
                     defined(dragonfly) or defined(macos) or
                     defined(linux) or defined(android) or
                     defined(solaris)

when defined(windows):
  import sets, hashes
elif unixPlatform:
  import ./selectors2
  from posix import EINTR, EAGAIN, EINPROGRESS, EWOULDBLOCK, MSG_PEEK,
                    MSG_NOSIGNAL
  from posix import SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT,
                    SIGBUS, SIGFPE, SIGKILL, SIGUSR1, SIGSEGV, SIGUSR2,
                    SIGPIPE, SIGALRM, SIGTERM, SIGPIPE
  export SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT,
         SIGBUS, SIGFPE, SIGKILL, SIGUSR1, SIGSEGV, SIGUSR2,
         SIGPIPE, SIGALRM, SIGTERM, SIGPIPE

type
  CallbackFunc* = proc (arg: pointer) {.gcsafe, raises: [Defect].}

  AsyncCallback* = object
    function*: CallbackFunc
    udata*: pointer

  AsyncError* = object of CatchableError
    ## Generic async exception
  AsyncTimeoutError* = object of AsyncError
    ## Timeout exception

  TimerCallback* = ref object
    finishAt*: Moment
    function*: AsyncCallback

  TrackerBase* = ref object of RootRef
    id*: string
    dump*: proc(): string {.gcsafe, raises: [Defect].}
    isLeaked*: proc(): bool {.gcsafe, raises: [Defect].}

  PDispatcherBase = ref object of RootRef
    timers*: HeapQueue[TimerCallback]
    callbacks*: Deque[AsyncCallback]
    idlers*: Deque[AsyncCallback]
    trackers*: Table[string, TrackerBase]

proc `<`(a, b: TimerCallback): bool =
  result = a.finishAt < b.finishAt

func getAsyncTimestamp*(a: Duration): auto {.inline.} =
  ## Return rounded up value of duration with milliseconds resolution.
  ##
  ## This function also take care on int32 overflow, because Linux and Windows
  ## accepts signed 32bit integer as timeout.
  let milsec = Millisecond.nanoseconds()
  let nansec = a.nanoseconds()
  var res = nansec div milsec
  let mid = nansec mod milsec
  when defined(windows):
    res = min(cast[int64](high(int32) - 1), res)
    result = cast[DWORD](res)
    result += DWORD(min(1'i32, cast[int32](mid)))
  else:
    res = min(cast[int64](high(int32) - 1), res)
    result = cast[int32](res)
    result += min(1, cast[int32](mid))

template processTimersGetTimeout(loop, timeout: untyped) =
  var lastFinish = curTime
  while loop.timers.len > 0:
    if loop.timers[0].function.function.isNil:
      discard loop.timers.pop()
      continue

    lastFinish = loop.timers[0].finishAt
    if curTime < lastFinish:
      break

    loop.callbacks.addLast(loop.timers.pop().function)

  if loop.timers.len > 0:
    timeout = (lastFinish - curTime).getAsyncTimestamp()

  if timeout == 0:
    if (len(loop.callbacks) == 0) and (len(loop.idlers) == 0):
      when defined(windows):
        timeout = INFINITE
      else:
        timeout = -1
  else:
    if (len(loop.callbacks) != 0) or (len(loop.idlers) != 0):
      timeout = 0

template processTimers(loop: untyped) =
  var curTime = Moment.now()
  while loop.timers.len > 0:
    if loop.timers[0].function.function.isNil:
      discard loop.timers.pop()
      continue

    if curTime < loop.timers[0].finishAt:
      break
    loop.callbacks.addLast(loop.timers.pop().function)

template processIdlers(loop: untyped) =
  if len(loop.idlers) > 0:
    loop.callbacks.addLast(loop.idlers.popFirst())

template processCallbacks(loop: untyped) =
  var count = len(loop.callbacks)
  for i in 0..<count:
    # This is mostly workaround for people which are using `waitFor` where
    # it must be used `await`. While using `waitFor` inside of callbacks
    # dispatcher's callback list is got decreased and length of
    # `loop.callbacks` become not equal to `count`, its why `IndexError`
    # can be generated.
    if len(loop.callbacks) == 0: break
    let callable = loop.callbacks.popFirst()
    if not isNil(callable.function):
      callable.function(callable.udata)

proc raiseAsDefect*(exc: ref Exception, msg: string) {.
    raises: [Defect], noreturn, noinline.} =
  # Reraise an exception as a Defect, where it's unexpected and can't be handled
  # We include the stack trace in the message because otherwise, it's easily
  # lost - Nim doesn't print it for `parent` exceptions for example (!)
  raise (ref Defect)(
    msg: msg & "\n" & exc.msg & "\n" & exc.getStackTrace(), parent: exc)

when defined(windows):
  type
    CompletionKey = ULONG_PTR

    CompletionData* = object
      cb*: CallbackFunc
      errCode*: OSErrorCode
      bytesCount*: uint32
      cell*: ForeignCell # we need this `cell` to protect our `cb` environment,
                         # when using `RegisterWaitForSingleObject()`, because
                         # waiting is done in different thread.
      udata*: pointer

    CustomOverlapped* = object of OVERLAPPED
      data*: CompletionData

    PDispatcher* = ref object of PDispatcherBase
      ioPort: HANDLE
      handles: HashSet[AsyncFD]
      connectEx*: WSAPROC_CONNECTEX
      acceptEx*: WSAPROC_ACCEPTEX
      getAcceptExSockAddrs*: WSAPROC_GETACCEPTEXSOCKADDRS
      transmitFile*: WSAPROC_TRANSMITFILE

    PtrCustomOverlapped* = ptr CustomOverlapped

    RefCustomOverlapped* = ref CustomOverlapped

    PostCallbackData = object
      ioPort: HANDLE
      handleFd: AsyncFD
      waitFd: HANDLE
      udata: pointer
      ovl: RefCustomOverlapped

    WaitableHandle* = ptr PostCallbackData

    WaitableResult* {.pure.} = enum
      Ok, Timeout

    AsyncFD* = distinct int

  proc hash(x: AsyncFD): Hash {.borrow.}
  proc `==`*(x: AsyncFD, y: AsyncFD): bool {.borrow, gcsafe.}

  proc getFunc(s: SocketHandle, fun: var pointer, guid: GUID): bool =
    var bytesRet: DWORD
    fun = nil
    wsaIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, unsafeAddr guid,
             sizeof(GUID).DWORD, addr fun, sizeof(pointer).DWORD,
             addr(bytesRet), nil, nil) == 0

  proc globalInit() {.raises: [Defect].} =
    var wsa: WSAData
    doAssert(wsaStartup(0x0202'u16, addr wsa) == 0,
             "Unable to initialize Windows Sockets API")

  proc initAPI(loop: PDispatcher) {.raises: [Defect].} =
    var funcPointer: pointer = nil
    let sock = socket(osdefs.AF_INET, 1, 6)
    doAssert(sock != osdefs.INVALID_SOCKET, "Unable to create control socket")
    doAssert(getFunc(sock, funcPointer, WSAID_CONNECTEX),
             "Unable to initialize dispatcher's ConnectEx() with error: " &
             osErrorMsg(osLastError()))
    loop.connectEx = cast[WSAPROC_CONNECTEX](funcPointer)
    doAssert(getFunc(sock, funcPointer, WSAID_ACCEPTEX),
             "Unable to initialize dispatcher's AcceptEx() with an error: " &
             osErrorMsg(osLastError()))
    loop.acceptEx = cast[WSAPROC_ACCEPTEX](funcPointer)
    doAssert(getFunc(sock, funcPointer, WSAID_GETACCEPTEXSOCKADDRS),
             "Unable to initialize dispatcher's GetAcceptExSockAddrs() with " &
             "an error: " & osErrorMsg(osLastError()))
    loop.getAcceptExSockAddrs = cast[WSAPROC_GETACCEPTEXSOCKADDRS](funcPointer)
    doAssert(getFunc(sock, funcPointer, WSAID_TRANSMITFILE),
             "Unable to initialize dispatcher's TransmitFile() with an " &
             "error: " & osErrorMsg(osLastError()))
    loop.transmitFile = cast[WSAPROC_TRANSMITFILE](funcPointer)
    doAssert(closeSocket(sock) == 0, "Unable to initialize dispatcher with " &
             "an error: " & osErrorMsg(osLastError()))

  proc newDispatcher*(): PDispatcher {.raises: [Defect].} =
    ## Creates a new Dispatcher instance.
    var res = PDispatcher()
    res.ioPort = createIoCompletionPort(osdefs.INVALID_HANDLE_VALUE,
                                        HANDLE(0), 0, 1)
    doAssert(res.ioPort != INVALID_HANDLE_VALUE, "Unable to create IOCP port")
    when declared(initHashSet):
      # After 0.20.0 Nim's stdlib version
      res.handles = initHashSet[AsyncFD]()
    else:
      # Pre 0.20.0 Nim's stdlib version
      res.handles = initSet[AsyncFD]()
    when declared(initHeapQueue):
      # After 0.20.0 Nim's stdlib version
      res.timers = initHeapQueue[TimerCallback]()
    else:
      # Pre 0.20.0 Nim's stdlib version
      res.timers = newHeapQueue[TimerCallback]()
    res.callbacks = initDeque[AsyncCallback](64)
    res.idlers = initDeque[AsyncCallback]()
    res.trackers = initTable[string, TrackerBase]()
    initAPI(res)
    res

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [Defect].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [Defect].}

  proc getIoHandler*(disp: PDispatcher): HANDLE =
    ## Returns the underlying IO Completion Port handle (Windows) or selector
    ## (Unix) for the specified dispatcher.
    return disp.ioPort

  proc register2*(fd: AsyncFD): Result[void, OSErrorCode] =
    let loop = getThreadDispatcher()
    if createIoCompletionPort(HANDLE(fd), loop.ioPort, cast[CompletionKey](fd),
                              1) == osdefs.INVALID_HANDLE_VALUE:
      return err(osLastError())
    loop.handles.incl(fd)
    ok()

  proc register*(fd: AsyncFD) {.raises: [Defect, OSError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    let res = register2(fd)
    if res.isErr():
      raiseOSError(res.error())

  proc unregister*(fd: AsyncFD) =
    ## Unregisters ``fd``.
    getThreadDispatcher().handles.excl(fd)

  {.push stackTrace: off.}
  proc waitableCallback(param: pointer, timerOrWaitFired: WINBOOL) {.
       stdcall, gcsafe.} =
    # This procedure will be executed in `wait thread`, so it must not use
    # GC related objects.
    # We going to ignore callbacks which was spawned when `isNil(param) == true`
    # because we unable to indicate this error.
    if isNil(param):
      return
    var wh = cast[WaitableHandle](param)
    # We ignore result of postQueueCompletionStatus() call because we unable to
    # indicate error.
    discard postQueuedCompletionStatus(wh.ioPort, DWORD(timerOrWaitFired),
                                       ULONG_PTR(wh.handleFd),
                                       cast[pointer](wh.ovl))
  {.pop.}

  proc registerWaitable(handle: Handle, flags: ULONG,
                        timeout: Duration, cb: CallbackFunc, udata: pointer
                        ): Result[WaitableHandle, OSErrorCode] =
    ## Register handle of (Change notification, Console input, Event,
    ## Memory resource notification, Mutex, Process, Semaphore, Thread,
    ## Waitable timer) for waiting, using specific Windows' ``flags`` and
    ## ``timeout`` value.
    ##
    ## Callback ``cb`` will be scheduled with ``udata`` parameter when
    ## ``handle`` become signaled.
    ##
    ## Result of this procedure call ``WaitableHandle`` should be closed using
    ## closeWaitable() call.
    ##
    ## NOTE: This is private procedure, not supposed to be publicly available,
    ## please use ``waitForSingleObject()``.
    let
      loop = getThreadDispatcher()
      handleFd = AsyncFD(handle)

    var ovl = RefCustomOverlapped(
      data: CompletionData(cb: cb, cell: system.protect(rawEnv(cb)))
    )
    GC_ref(ovl)
    var whandle = cast[WaitableHandle](allocShared0(sizeof(PostCallbackData)))
    whandle.ioPort = loop.getIoHandler()
    whandle.handleFd = AsyncFD(handle)
    whandle.udata = udata
    whandle.ovl = ovl
    ovl.data.udata = cast[pointer](whandle)

    let dwordTimeout =
      if timeout == InfiniteDuration:
        DWORD(INFINITE)
      else:
        DWORD(timeout.milliseconds)

    if registerWaitForSingleObject(addr whandle.waitFd, handle,
                                   cast[WAITORTIMERCALLBACK](waitableCallback),
                                   cast[pointer](whandle),
                                   dwordTimeout,
                                   flags) == WINBOOL(0):
      system.dispose(ovl.data.cell)
      ovl.data.udata = nil
      GC_unref(ovl)
      deallocShared(cast[pointer](whandle))
      return err(osLastError())

    ok(whandle)

  proc closeWaitable(wh: WaitableHandle): Result[void, OSErrorCode] =
    ## Close waitable handle ``wh`` and clear all the resources. It is safe
    ## to close this handle, even if wait operation is pending.
    ##
    ## NOTE: This is private procedure, not supposed to be publicly available,
    ## please use ``waitForSingleObject()``.
    let
      handleFd = wh.handleFd
      waitFd = wh.waitFd

    system.dispose(wh.ovl.data.cell)
    GC_unref(wh.ovl)
    deallocShared(cast[pointer](wh))

    if unregisterWait(waitFd) == 0:
      let res = osLastError()
      if res != ERROR_IO_PENDING:
        return err(res)
    ok()

  proc addProcess2*(pid: int, cb: CallbackFunc,
                    udata: pointer = nil): Result[int, OSErrorCode] =
    ## Registers callback ``cb`` to be called when process with process
    ## identifier ``pid`` exited. Returns process identifier, which can be
    ## used to clear process callback via ``removeProcess``.
    doAssert(pid > 0, "Process identifier must be positive integer")
    let
      loop = getThreadDispatcher()
      hProcess = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
      flags = WT_EXECUTEINWAITTHREAD or WT_EXECUTEONLYONCE

    var wh: WaitableHandle = nil

    if hProcess == Handle(0):
      return err(osLastError())

    proc continuation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(udata)))
      doAssert(not(isNil(wh)))

      let
        ovl = cast[CustomOverlapped](udata)
        udata = ovl.data.udata
      # We ignore result here because its not possible to indicate an error.
      discard closeWaitable(wh)
      discard closeHandle(hProcess)
      cb(udata)

    wh =
      block:
        let res = registerWaitable(hProcess, flags, InfiniteDuration,
                                   continuation, udata)
        if res.isErr():
          discard closeHandle(hProcess)
          return err(res.error())
        res.get()
    ok(cast[int](wh))

  proc addProcess*(pid: int, cb: CallbackFunc, udata: pointer = nil): int {.
       raises: [Defect, ValueError].} =
    ## Registers callback ``cb`` to be called when process with process
    ## identifier ``pid`` exited. Returns process identifier, which can be
    ## used to clear process callback via ``removeProcess``.
    let res = addProcess2(pid, cb, udata)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))
    res.get()

  proc removeProcess*(procfd: int) {.
       raises: [Defect, ValueError].} =
    ## Remove process' watching using process' descriptor ``procfd``.
    doAssert(procfd != 0)
    # WaitableHandle is allocated in shared memory, so it is not managed by GC.
    let wh = cast[WaitableHandle](procfd)
    let res = closeWaitable(wh)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc poll*() {.raises: [Defect, CatchableError].} =
    ## Perform single asynchronous step, processing timers and completing
    ## unblocked tasks. Blocks until at least one event has completed.
    ##
    ## Exceptions raised here indicate that waiting for tasks to be unblocked
    ## failed - exceptions from within tasks are instead propagated through
    ## their respective futures and not allowed to interrrupt the poll call.
    let loop = getThreadDispatcher()
    var curTime = Moment.now()
    var curTimeout = DWORD(0)
    var noNetworkEvents = false

    # Moving expired timers to `loop.callbacks` and calculate timeout
    loop.processTimersGetTimeout(curTimeout)

    # Processing handles
    var lpNumberOfBytesTransferred: DWORD
    var lpCompletionKey: ULONG_PTR
    var customOverlapped: PtrCustomOverlapped

    let res = getQueuedCompletionStatus(
      loop.ioPort, addr lpNumberOfBytesTransferred,
      addr lpCompletionKey, cast[ptr POVERLAPPED](addr customOverlapped),
      curTimeout).bool

    if res:
      customOverlapped.data.bytesCount = lpNumberOfBytesTransferred
      customOverlapped.data.errCode = OSErrorCode(-1)
      let acb = AsyncCallback(function: customOverlapped.data.cb,
                              udata: cast[pointer](customOverlapped))
      loop.callbacks.addLast(acb)
    else:
      let errCode = osLastError()
      if customOverlapped != nil:
        customOverlapped.data.errCode = errCode
        let acb = AsyncCallback(function: customOverlapped.data.cb,
                                udata: cast[pointer](customOverlapped))
        loop.callbacks.addLast(acb)
      else:
        if DWORD(errCode) != WAIT_TIMEOUT:
          raiseOSError(errCode)
        else:
          noNetworkEvents = true

    # Moving expired timers to `loop.callbacks`.
    loop.processTimers()

    # We move idle callbacks to `loop.callbacks` only if there no pending
    # network events.
    if noNetworkEvents:
      loop.processIdlers()

    # All callbacks which will be added in process will be processed on next
    # poll() call.
    loop.processCallbacks()

  proc closeSocket*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a socket and ensures that it is unregistered.
    let loop = getThreadDispatcher()
    loop.handles.excl(fd)
    let param =
      if osdefs.closeSocket(SocketHandle(fd)) == 0:
        OSErrorCode(0)
      else:
        osLastError()
    if not isNil(aftercb):
      var acb = AsyncCallback(function: aftercb, udata: cast[pointer](param))
      loop.callbacks.addLast(acb)

  proc closeHandle*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a (pipe/file) handle and ensures that it is unregistered.
    let loop = getThreadDispatcher()
    loop.handles.excl(fd)
    let param =
      if osdefs.closeHandle(HANDLE(fd)) == TRUE:
        OSErrorCode(0)
      else:
        osLastError()
    if not isNil(aftercb):
      var acb = AsyncCallback(function: aftercb, udata: cast[pointer](param))
      loop.callbacks.addLast(acb)

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool =
    ## Returns ``true`` if ``fd`` is registered in thread's dispatcher.
    fd in disp.handles

elif unixPlatform:
  const
    SIG_IGN = cast[proc(x: cint) {.raises: [], noconv, gcsafe.}](1)

  type
    AsyncFD* = distinct cint

    SelectorData* = object
      reader*: AsyncCallback
      writer*: AsyncCallback

    PDispatcher* = ref object of PDispatcherBase
      selector: Selector[SelectorData]
      keys: seq[ReadyKey]

  proc `==`*(x, y: AsyncFD): bool {.borrow, gcsafe.}

  proc globalInit() =
    # We are ignoring SIGPIPE signal, because we are working with EPIPE.
    signal(cint(SIGPIPE), SIG_IGN)

  proc initAPI(disp: PDispatcher) {.raises: [Defect].} =
    discard

  proc newDispatcher*(): PDispatcher {.raises: [Defect].} =
    ## Create new dispatcher.
    var res = PDispatcher()
    res.selector =
      block:
        let res = Selector.new(SelectorData)
        doAssert(res.isOk(),
                 "Could not initalize selector with error: " &
                 osErrorMsg(res.error()))
        res.get()
    when declared(initHeapQueue):
      # After 0.20.0 Nim's stdlib version
      res.timers = initHeapQueue[TimerCallback]()
    else:
      # Before 0.20.0 Nim's stdlib version
      res.timers.newHeapQueue()
    res.callbacks = initDeque[AsyncCallback](64)
    res.idlers = initDeque[AsyncCallback]()
    res.keys = newSeq[ReadyKey](64)
    res.trackers = initTable[string, TrackerBase]()
    initAPI(res)
    res

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [Defect].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [Defect].}

  proc getIoHandler*(disp: PDispatcher): Selector[SelectorData] =
    ## Returns system specific OS queue.
    return disp.selector

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool {.inline.} =
    ## Returns ``true`` if ``fd`` is registered in thread's dispatcher.
    int(fd) in disp.selector

  proc register2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    var data: SelectorData
    getThreadDispatcher().selector.registerHandle2(cint(fd), {}, data)

  proc unregister2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    getThreadDispatcher().selector.unregister2(cint(fd))

  proc addReader2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let loop = getThreadDispatcher()
    var newEvents = {Event.Read}
    withData(loop.selector, int(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.reader = acb
      newEvents.incl(Event.Read)
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(OSErrorCode(osdefs.EINVAL))
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc removeReader2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for read availability.
    let loop = getThreadDispatcher()
    var newEvents: set[Event]
    withData(loop.selector, int(fd), adata) do:
      # We need to clear `reader` data, because `selectors` don't do it
      adata.reader = default(AsyncCallback)
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(OSErrorCode(osdefs.EINVAL))
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc addWriter2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let loop = getThreadDispatcher()
    var newEvents = {Event.Write}
    withData(loop.selector, int(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.writer = acb
      newEvents.incl(Event.Write)
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(OSErrorCode(osdefs.EINVAL))
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc removeWriter2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for write availability.
    let loop = getThreadDispatcher()
    var newEvents: set[Event]
    withData(loop.selector, int(fd), adata) do:
      # We need to clear `writer` data, because `selectors` don't do it
      adata.writer = default(AsyncCallback)
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(OSErrorCode(osdefs.EINVAL))
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc register*(fd: AsyncFD) {.raises: [Defect, AsyncError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    let res = register2(fd)
    if res.isErr():
      raise newException(AsyncError, osErrorMsg(res.error()))

  proc unregister*(fd: AsyncFD) {.raises: [Defect, AsyncError].} =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    let res = unregister2(fd)
    if res.isErr():
      raise newException(AsyncError, osErrorMsg(res.error()))

  proc addReader*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
      raises: [Defect, ValueError].} =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let res = addReader2(fd, cb, udata)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc removeReader*(fd: AsyncFD) {.
       raises: [Defect, ValueError].} =
    ## Stop watching the file descriptor ``fd`` for read availability.
    let res = removeReader2(fd)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc addWriter*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
       raises: [Defect, ValueError].} =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let res = addWriter2(fd, cb, udata)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc removeWriter*(fd: AsyncFD) {.
       raises: [Defect, ValueError].} =
    let res = removeWriter2(fd)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc closeSocket*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous socket.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    let loop = getThreadDispatcher()

    proc continuation(udata: pointer) =
      let param =
        if int(fd) in loop.selector:
          let ures = unregister2(fd)
          if ures.isErr():
            discard handleEintr(osdefs.close(cint(fd)))
            ures.error()
          else:
            if handleEintr(osdefs.close(cint(fd))) != 0:
              osLastError()
            else:
              OSErrorCode(0)
        else:
          OSErrorCode(EINVAL)

      if not isNil(aftercb):
        aftercb(cast[pointer](param))

    withData(loop.selector, int(fd), adata) do:
      # We are scheduling reader and writer callbacks to be called
      # explicitly, so they can get an error and continue work.
      # Callbacks marked as deleted so we don't need to get REAL notifications
      # from system queue for this reader and writer.

      if not(isNil(adata.reader.function)):
        loop.callbacks.addLast(adata.reader)
        adata.reader = default(AsyncCallback)

      if not(isNil(adata.writer.function)):
        loop.callbacks.addLast(adata.writer)
        adata.writer = default(AsyncCallback)

    # We can't unregister file descriptor from system queue here, because
    # in such case processing queue will stuck on poll() call, because there
    # can be no file descriptors registered in system queue.
    var acb = AsyncCallback(function: continuation)
    loop.callbacks.addLast(acb)

  proc closeHandle*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous file/pipe handle.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    ## You can execute ``aftercb`` before actual socket close operation.
    closeSocket(fd, aftercb)

  when ioselSupportedPlatform:
    proc addSignal2*(signal: int, cb: CallbackFunc,
                      udata: pointer = nil): Result[int, OSErrorCode] =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      let loop = getThreadDispatcher()
      var data: SelectorData
      let sigfd = ? loop.selector.registerSignal(signal, data)
      withData(loop.selector, sigfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(OSErrorCode(osdefs.EINVAL))
      ok(sigfd)

    proc addProcess2*(pid: int, cb: CallbackFunc,
                      udata: pointer = nil): Result[int, OSErrorCode] =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process' descriptor, which can be
      ## used to clear process callback via ``removeProcess``.
      let loop = getThreadDispatcher()
      var data: SelectorData
      let procfd = ? loop.selector.registerProcess(pid, data)
      withData(loop.selector, procfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(OSErrorCode(osdefs.EINVAL))
      ok(procfd)

    proc removeSignal2*(sigfd: int): Result[void, OSErrorCode] =
      ## Remove watching signal ``signal``.
      let loop = getThreadDispatcher()
      loop.selector.unregister2(cint(sigfd))

    proc removeProcess2*(procfd: int): Result[void, OSErrorCode] =
      ## Remove process' watching using process' descriptor ``procfd``.
      let loop = getThreadDispatcher()
      loop.selector.unregister2(cint(procfd))

    proc addSignal*(signal: int, cb: CallbackFunc, udata: pointer = nil): int {.
         raises: [Defect, ValueError].} =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      let res = addSignal2(signal, cb, udata)
      if res.isErr():
        raise newException(ValueError, osErrorMsg(res.error()))
      res.get()

    proc addProcess*(pid: int, cb: CallbackFunc, udata: pointer = nil): int {.
         raises: [Defect, ValueError].} =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process' descriptor, which can be
      ## used to clear process callback via ``removeProcess``.
      let res = addProcess2(pid, cb, udata)
      if res.isErr():
        raise newException(ValueError, osErrorMsg(res.error()))
      res.get()

    proc removeSignal*(sigfd: int) {.
         raises: [Defect, IOSelectorsException].} =
      ## Remove watching signal ``signal``.
      let res = removeSignal2(sigfd)
      if res.isErr():
        raise newException(IOSelectorsException, osErrorMsg(res.error()))

    proc removeProcess*(procfd: int) {.
         raises: [Defect, IOSelectorsException].} =
      ## Remove process' watching using process' descriptor ``procfd``.
      let res = removeProcess2(procfd)
      if res.isErr():
        raise newException(IOSelectorsException, osErrorMsg(res.error()))

  proc poll*() {.raises: [Defect].} =
    ## Perform single asynchronous step.
    let loop = getThreadDispatcher()
    var curTime = Moment.now()
    var curTimeout = 0

    when ioselSupportedPlatform:
      let customSet = {Event.Timer, Event.Signal, Event.Process,
                       Event.Vnode}

    # Moving expired timers to `loop.callbacks` and calculate timeout.
    loop.processTimersGetTimeout(curTimeout)

    # Processing IO descriptors and all hardware events.
    let count =
      block:
        let res = loop.selector.selectInto2(curTimeout, loop.keys)
        doAssert(res.isOk(), "Selector failed with error: " &
                 osErrorMsg(res.error()))
        res.get()

    for i in 0 ..< count:
      let fd = loop.keys[i].fd
      let events = loop.keys[i].events

      withData(loop.selector, fd, adata) do:
        if (Event.Read in events) or (events == {Event.Error}):
          if not isNil(adata.reader.function):
            loop.callbacks.addLast(adata.reader)

        if (Event.Write in events) or (events == {Event.Error}):
          if not isNil(adata.writer.function):
            loop.callbacks.addLast(adata.writer)

        if Event.User in events:
          if not isNil(adata.reader.function):
            loop.callbacks.addLast(adata.reader)

        when ioselSupportedPlatform:
          if customSet * events != {}:
            if not isNil(adata.reader.function):
              loop.callbacks.addLast(adata.reader)

    # Moving expired timers to `loop.callbacks`.
    loop.processTimers()

    # We move idle callbacks to `loop.callbacks` only if there no pending
    # network events.
    if count == 0:
      loop.processIdlers()

    # All callbacks which will be added in process, will be processed on next
    # poll() call.
    loop.processCallbacks()

else:
  proc initAPI() = discard
  proc globalInit() = discard

proc setThreadDispatcher*(disp: PDispatcher) =
  ## Set current thread's dispatcher instance to ``disp``.
  if not gDisp.isNil:
    doAssert gDisp.callbacks.len == 0
  gDisp = disp

proc getThreadDispatcher*(): PDispatcher =
  ## Returns current thread's dispatcher instance.
  if gDisp.isNil:
    try:
      setThreadDispatcher(newDispatcher())
    except CatchableError as exc:
      raiseAsDefect exc, "Cannot create dispatcher"
  gDisp

proc setGlobalDispatcher*(disp: PDispatcher) {.
      gcsafe, deprecated: "Use setThreadDispatcher() instead".} =
  setThreadDispatcher(disp)

proc getGlobalDispatcher*(): PDispatcher {.
      gcsafe, deprecated: "Use getThreadDispatcher() instead".} =
  getThreadDispatcher()

proc setTimer*(at: Moment, cb: CallbackFunc,
               udata: pointer = nil): TimerCallback =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  let loop = getThreadDispatcher()
  result = TimerCallback(finishAt: at,
                         function: AsyncCallback(function: cb, udata: udata))
  loop.timers.push(result)

proc clearTimer*(timer: TimerCallback) {.inline.} =
  timer.function = default(AsyncCallback)

proc addTimer*(at: Moment, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use setTimer/clearTimer instead".} =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  discard setTimer(at, cb, udata)

proc addTimer*(at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(Moment.init(at, Millisecond), cb, udata)

proc addTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(Moment.init(int64(at), Millisecond), cb, udata)

proc removeTimer*(at: Moment, cb: CallbackFunc, udata: pointer = nil) =
  ## Remove timer callback ``cb`` with absolute timestamp ``at`` from waiting
  ## queue.
  let loop = getThreadDispatcher()
  var list = cast[seq[TimerCallback]](loop.timers)
  var index = -1
  for i in 0..<len(list):
    if list[i].finishAt == at and list[i].function.function == cb and
       list[i].function.udata == udata:
      index = i
      break
  if index != -1:
    loop.timers.del(index)

proc removeTimer*(at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(Moment.init(at, Millisecond), cb, udata)

proc removeTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(Moment.init(int64(at), Millisecond), cb, udata)

proc callSoon*(acb: AsyncCallback) {.gcsafe, raises: [Defect].} =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.
  getThreadDispatcher().callbacks.addLast(acb)

proc callSoon*(cbproc: CallbackFunc, data: pointer) {.
     gcsafe, raises: [Defect].} =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.
  doAssert(not isNil(cbproc))
  callSoon(AsyncCallback(function: cbproc, udata: data))

proc callSoon*(cbproc: CallbackFunc) {.gcsafe, raises: [Defect].} =
  callSoon(cbproc, nil)

proc callIdle*(acb: AsyncCallback) {.gcsafe, raises: [Defect].} =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every loop
  ## iteration if there no network events available, not when the loop is
  ## actually "idle".
  getThreadDispatcher().idlers.addLast(acb)

proc callIdle*(cbproc: CallbackFunc, data: pointer) {.
     gcsafe, raises: [Defect].} =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every loop
  ## iteration if there no network events available, not when the loop is
  ## actually "idle".
  doAssert(not isNil(cbproc))
  callIdle(AsyncCallback(function: cbproc, udata: data))

proc callIdle*(cbproc: CallbackFunc) {.gcsafe, raises: [Defect].} =
  callIdle(cbproc, nil)

include asyncfutures2

when not(defined(windows)):
  when ioselSupportedPlatform:
    proc waitSignal*(signal: int): Future[void] {.
         raises: [Defect].} =
      var retFuture = newFuture[void]("chronos.waitSignal()")
      var sigfd: int = -1

      template getSignalException(e: untyped): untyped =
        newException(AsyncError, "Could not manipulate signal handler, " &
                     "reason [" & $e.name & "]: " & $e.msg)

      proc continuation(udata: pointer) {.gcsafe.} =
        if not(retFuture.finished()):
          if sigfd != -1:
            try:
              removeSignal(sigfd)
              retFuture.complete()
            except IOSelectorsException as exc:
              retFuture.fail(getSignalException(exc))

      proc cancellation(udata: pointer) {.gcsafe.} =
        if not(retFuture.finished()):
          if sigfd != -1:
            try:
              removeSignal(sigfd)
            except IOSelectorsException as exc:
              retFuture.fail(getSignalException(exc))

      sigfd =
        try:
          addSignal(signal, continuation)
        except IOSelectorsException as exc:
          retFuture.fail(getSignalException(exc))
          return retFuture
        except ValueError as exc:
          retFuture.fail(getSignalException(exc))
          return retFuture
        except OSError as exc:
          retFuture.fail(getSignalException(exc))
          return retFuture

      retFuture.cancelCallback = cancellation
      retFuture

proc sleepAsync*(duration: Duration): Future[void] =
  ## Suspends the execution of the current async procedure for the next
  ## ``duration`` time.
  var retFuture = newFuture[void]("chronos.sleepAsync(Duration)")
  let moment = Moment.fromNow(duration)
  var timer: TimerCallback

  proc completion(data: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      clearTimer(timer)

  retFuture.cancelCallback = cancellation
  timer = setTimer(moment, completion, cast[pointer](retFuture))
  return retFuture

proc sleepAsync*(ms: int): Future[void] {.
     inline, deprecated: "Use sleepAsync(Duration)".} =
  result = sleepAsync(ms.milliseconds())

proc stepsAsync*(number: int): Future[void] =
  ## Suspends the execution of the current async procedure for the next
  ## ``number`` of asynchronous steps (``poll()`` calls).
  ##
  ## This primitive can be useful when you need to create more deterministic
  ## tests and cases.
  ##
  ## WARNING! Do not use this primitive to perform switch between tasks, because
  ## this can lead to 100% CPU load in the moments when there are no I/O
  ## events. Usually when there no I/O events CPU consumption should be near 0%.
  var retFuture = newFuture[void]("chronos.stepsAsync(int)")
  var counter = 0

  var continuation: proc(data: pointer) {.gcsafe, raises: [Defect].}
  continuation = proc(data: pointer) {.gcsafe, raises: [Defect].} =
    if not(retFuture.finished()):
      inc(counter)
      if counter < number:
        callSoon(continuation, nil)
      else:
        retFuture.complete()

  proc cancellation(udata: pointer) =
    discard

  if number <= 0:
    retFuture.complete()
  else:
    retFuture.cancelCallback = cancellation
    callSoon(continuation, nil)

  retFuture

proc idleAsync*(): Future[void] =
  ## Suspends the execution of the current asynchronous task until "idle" time.
  ##
  ## "idle" time its moment of time, when no network events were processed by
  ## ``poll()`` call.
  var retFuture = newFuture[void]("chronos.idleAsync()")

  proc continuation(data: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    discard

  retFuture.cancelCallback = cancellation
  callIdle(continuation, nil)
  retFuture

proc withTimeout*[T](fut: Future[T], timeout: Duration): Future[bool] =
  ## Returns a future which will complete once ``fut`` completes or after
  ## ``timeout`` milliseconds has elapsed.
  ##
  ## If ``fut`` completes first the returned future will hold true,
  ## otherwise, if ``timeout`` milliseconds has elapsed first, the returned
  ## future will hold false.
  var retFuture = newFuture[bool]("chronos.`withTimeout`")
  var moment: Moment
  var timer: TimerCallback
  var cancelling = false

  # TODO: raises annotation shouldn't be needed, but likely similar issue as
  # https://github.com/nim-lang/Nim/issues/17369
  proc continuation(udata: pointer) {.gcsafe, raises: [Defect].} =
    if not(retFuture.finished()):
      if not(cancelling):
        if not(fut.finished()):
          # Timer exceeded first, we going to cancel `fut` and wait until it
          # not completes.
          cancelling = true
          fut.cancel()
        else:
          # Future `fut` completed/failed/cancelled first.
          if not(isNil(timer)):
            clearTimer(timer)
          retFuture.complete(true)
      else:
        retFuture.complete(false)

  # TODO: raises annotation shouldn't be needed, but likely similar issue as
  # https://github.com/nim-lang/Nim/issues/17369
  proc cancellation(udata: pointer) {.gcsafe, raises: [Defect].} =
    if not isNil(timer):
      clearTimer(timer)
    if not(fut.finished()):
      fut.removeCallback(continuation)
      fut.cancel()

  if fut.finished():
    retFuture.complete(true)
  else:
    if timeout.isZero():
      retFuture.complete(false)
    elif timeout.isInfinite():
      retFuture.cancelCallback = cancellation
      fut.addCallback(continuation)
    else:
      moment = Moment.fromNow(timeout)
      retFuture.cancelCallback = cancellation
      timer = setTimer(moment, continuation, nil)
      fut.addCallback(continuation)

  return retFuture

proc withTimeout*[T](fut: Future[T], timeout: int): Future[bool] {.
     inline, deprecated: "Use withTimeout(Future[T], Duration)".} =
  result = withTimeout(fut, timeout.milliseconds())

proc wait*[T](fut: Future[T], timeout = InfiniteDuration): Future[T] =
  ## Returns a future which will complete once future ``fut`` completes
  ## or if timeout of ``timeout`` milliseconds has been expired.
  ##
  ## If ``timeout`` is ``-1``, then statement ``await wait(fut)`` is
  ## equal to ``await fut``.
  ##
  ## TODO: In case when ``fut`` got cancelled, what result Future[T]
  ## should return, because it can't be cancelled too.
  var retFuture = newFuture[T]("chronos.wait()")
  var moment: Moment
  var timer: TimerCallback
  var cancelling = false

  proc continuation(udata: pointer) {.raises: [Defect].} =
    if not(retFuture.finished()):
      if not(cancelling):
        if not(fut.finished()):
          # Timer exceeded first.
          cancelling = true
          fut.cancel()
        else:
          # Future `fut` completed/failed/cancelled first.
          if not isNil(timer):
            clearTimer(timer)

          if fut.failed():
            retFuture.fail(fut.error)
          else:
            when T is void:
              retFuture.complete()
            else:
              retFuture.complete(fut.value)
      else:
        retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))

  var cancellation: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  cancellation = proc(udata: pointer) {.gcsafe, raises: [Defect].} =
    if not isNil(timer):
      clearTimer(timer)
    if not(fut.finished()):
      fut.removeCallback(continuation)
      fut.cancel()

  if fut.finished():
    if fut.failed():
      retFuture.fail(fut.error)
    else:
      when T is void:
        retFuture.complete()
      else:
        retFuture.complete(fut.value)
  else:
    if timeout.isZero():
      retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))
    elif timeout.isInfinite():
      retFuture.cancelCallback = cancellation
      fut.addCallback(continuation)
    else:
      moment = Moment.fromNow(timeout)
      retFuture.cancelCallback = cancellation
      timer = setTimer(moment, continuation, nil)
      fut.addCallback(continuation)

  return retFuture

proc wait*[T](fut: Future[T], timeout = -1): Future[T] {.
     inline, deprecated: "Use wait(Future[T], Duration)".} =
  if timeout == -1:
    wait(fut, InfiniteDuration)
  elif timeout == 0:
    wait(fut, ZeroDuration)
  else:
    wait(fut, timeout.milliseconds())

include asyncmacro2

proc runForever*() {.raises: [Defect, CatchableError].} =
  ## Begins a never ending global dispatcher poll loop.
  ## Raises different exceptions depending on the platform.
  while true:
    poll()

proc waitFor*[T](fut: Future[T]): T {.raises: [Defect, CatchableError].} =
  ## **Blocks** the current thread until the specified future completes.
  ## There's no way to tell if poll or read raised the exception
  while not(fut.finished()):
    poll()

  fut.read()

proc addTracker*[T](id: string, tracker: T) =
  ## Add new ``tracker`` object to current thread dispatcher with identifier
  ## ``id``.
  let loop = getThreadDispatcher()
  loop.trackers[id] = tracker

proc getTracker*(id: string): TrackerBase =
  ## Get ``tracker`` from current thread dispatcher using identifier ``id``.
  let loop = getThreadDispatcher()
  result = loop.trackers.getOrDefault(id, nil)

when defined(chronosFutureTracking):
  iterator pendingFutures*(): FutureBase =
    ## Iterates over the list of pending Futures (Future[T] objects which not
    ## yet completed, cancelled or failed).
    var slider = futureList.head
    while not(isNil(slider)):
      yield slider
      slider = slider.next

  proc pendingFuturesCount*(): uint =
    ## Returns number of pending Futures (Future[T] objects which not yet
    ## completed, cancelled or failed).
    futureList.count

when defined(windows):
  proc waitForSingleObject*(handle: HANDLE,
                            timeout: Duration): Future[WaitableResult] {.
       raises: [Defect].} =
    ## Wait for Windows' handle in asynchronous way.
    let
      loop = getThreadDispatcher()
      flags = WT_EXECUTEONLYONCE

    var
      retFuture = newFuture[WaitableResult]("chronos.waitForSingleObject()")
      waitHandle: WaitableHandle = nil

    proc continuation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(waitHandle)))
      if not(retFuture.finished()):
        let
          ovl = cast[PtrCustomOverlapped](udata)
          returnFlag = WINBOOL(ovl.data.bytesCount)
          res = closeWaitable(waitHandle)
        if res.isErr():
          retFuture.fail(newException(ValueError, osErrorMsg(res.error())))
        else:
          if returnFlag == TRUE:
            retFuture.complete(WaitableResult.Timeout)
          else:
            retFuture.complete(WaitableResult.Ok)

    proc cancellation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(waitHandle)))
      if not(retFuture.finished()):
        discard closeWaitable(waitHandle)

    let wres = uint32(waitForSingleObject(handle, DWORD(0)))
    if wres == WAIT_OBJECT_0:
      retFuture.complete(WaitableResult.Ok)
      return retFuture
    elif wres == WAIT_ABANDONED:
      retFuture.fail(newException(ValueError, "Handle was abandoned"))
      return retFuture
    elif wres == WAIT_FAILED:
      retFuture.fail(newException(ValueError, osErrorMsg(osLastError())))
      return retFuture

    if timeout == ZeroDuration:
      retFuture.complete(WaitableResult.Timeout)
      return retFuture

    waitHandle =
      block:
        let res = registerWaitable(handle, flags, timeout, continuation, nil)
        if res.isErr():
          retFuture.fail(newException(ValueError, osErrorMsg(res.error())))
          return retFuture
        res.get()

    retFuture.cancelCallback = cancellation
    return retFuture

# Perform global per-module initialization.
globalInit()
