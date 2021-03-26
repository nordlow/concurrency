module concurrency.stream;

import concurrency.stoptoken;
import concurrency.receiver;
import concurrency.sender : isSender;
import concepts;

/// A Stream is anything that has a `.collect` function that accepts a callable and returns a Sender.
/// Once the Sender is connected and started the Stream will call the callable zero or more times before one of the three terminal functions of the Receiver is called.

/// checks that T is a Stream
void checkStream(T)() {
  import std.traits : ReturnType;
  static if (is(T.ElementType == void)) {
    alias DG = void delegate();
  } else {
    alias DG = void delegate(T.ElementType);
  }
  alias Sender = ReturnType!(T.connect!(DG));
  static assert (models!(Sender, isSender));
}
enum isStream(T) = is(typeof(checkStream!T));

/*
  catch?
  combineLatest
  count
  debounce
  distinctUntilChanged
  drop
  dropWhile
  filter
  first
  firstOrNull
  flatMapConcat
  flatMapLatest
  flatMapMerge
  fold
  map
  mapLatest
  merge
  onEach
  onEmpty
  onStart
  onSubscription
  reduce (fold with no seed)
  retry
  retryWhen
  runningReduce
  sample
  scan (like runningReduce but with initial value)
  take
  takeWhile
  toList
  transform
  transformLatest
  zip
*/

/// Helper to construct a Stream, useful if the Stream you are modeling has a blocking loop
template loopStream(E) {
  auto loopStream(T)(T t) {
    struct LoopStream {
      alias ElementType = E;
      static struct LoopOp(DG, Receiver) {
        T t;
        DG dg;
        Receiver receiver;
        void start() {
          try {
            t.loop(dg, receiver.getStopToken);
          } catch (Exception e) {
            receiver.setError(e);
          }
          if (receiver.getStopToken().isStopRequested)
            receiver.setDone();
          else
            receiver.setValue();
        }
      }
      static struct LoopSender(DG) {
        alias Value = void;
        T t;
        DG dg;
        auto connect(Receiver)(Receiver receiver) {
          return LoopOp!(DG, Receiver)(t, dg, receiver);
        }
      }
      T t;
      auto collect(DG)(DG dg) {
        return LoopSender!(DG)(t, dg);
      }
    }
    return LoopStream(t);
  }
}

/// Helper to construct a Stream, useful if the Stream you are modeling has an external source that should be started/stopped
template startStopStream(E) {
  auto startStopStream(T)(T t) {
    struct StartStopStream {
      alias ElementType = E;
      static struct StartStopOp(DG, Receiver) {
        T t;
        DG dg;
        Receiver receiver;
        void start() {
          t.start(dg, receiver.getStopToken);
          receiver.getStopToken.onStop(&(cast(shared)this).stop);
        }
        void stop() shared @trusted nothrow {
          try {
            (cast()t).stop();
          } catch (Exception e) {}
          (cast()receiver).setDone();
        }
      }
      static struct StartStopSender(DG) {
        alias Value = void;
        T t;
        DG dg;
        auto connect(Receiver)(Receiver receiver) {
          return StartStopOp!(DG, Receiver)(t, dg, receiver);
        }
      }
      T t;
      auto collect(DG)(DG dg) {
        return StartStopSender!(DG)(t, dg);
      }
    }
    return StartStopStream(t);
  }
}

/// Stream that emit the same value until cancelled
auto infiniteStream(T)(T t) {
  struct Loop {
    T val;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {
      while(!stopToken.isStopRequested)
        emit(val);
    }
  }
  return Loop(t).loopStream!T;
}

/// Stream that emits from start..end or until cancelled
auto iotaStream(T)(T start, T end) {
  struct Loop {
    T b,e;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {
      foreach(i; b..e) {
        emit(i);
        if (stopToken.isStopRequested)
          break;
      }
    }
  }
  return Loop(start, end).loopStream!T;
}

/// Stream that emits each value from the array or until cancelled
auto arrayStream(T)(T[] arr) {
  struct Loop {
    T[] arr;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {
      foreach(item; arr) {
        emit(item);
        if (stopToken.isStopRequested)
          break;
      }
    }
  }
  return Loop(arr).loopStream!T;
}

import core.time : Duration;

/// Stream that emits after each duration or until cancelled
auto intervalStream(Duration duration) {
  static struct Loop {
    Duration duration;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {

      if (stopToken.isStopRequested)
        return;

      // TODO: waiting should really be a feature of the scheduler, because it depends on if we are in a thread, fiber, coroutine or an eventloop
      version (Windows) {
        import core.sync.mutex : Mutex;
        import core.sync.condition : Condition;

        auto m = new Mutex();
        auto cond = new Condition(m);
        auto cb = stopToken.onStop(cast(void delegate() shared nothrow @safe)() nothrow @trusted {
            m.lock_nothrow();
            scope (exit)
              m.unlock_nothrow();
            try {
              cond.notify();
            }
            catch (Exception e) {
              assert(false, e.msg);
            }
          });
        scope (exit)
          cb.dispose();

        /// wait returns true if notified, we want to return false in that case as it signifies cancellation
        m.lock_nothrow();
        scope(exit) m.unlock_nothrow();
        while (!cond.wait(duration)) {
          m.unlock_nothrow();
          emit();
          m.lock_nothrow();
        }
        receiver.setDone();
      } else version (linux) {
        import core.sys.linux.timerfd;
        import core.sys.linux.sys.eventfd;
        import core.sys.posix.sys.select;
        import std.exception : ErrnoException;
        import core.sys.posix.unistd;
        import core.stdc.errno;

        shared int stopfd = eventfd(0, EFD_CLOEXEC);
        if (stopfd == -1)
          throw new ErrnoException("eventfd failed");

        auto stopCb = stopToken.onStop(() shared @trusted {
            ulong b = 1;
            write(stopfd, &b, typeof(b).sizeof);
          });
        scope (exit) {
          stopCb.dispose();
          close(stopfd);
        }

      auto when = duration.split!("seconds", "usecs");
      while(!stopToken.isStopRequested) {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(stopfd, &read_fds);
        timeval tv;
        tv.tv_sec = when.seconds;
        tv.tv_usec = when.usecs;
      retry:
        const ret = select(stopfd + 1, &read_fds, null, null, &tv);
        if (ret == 0) {
          emit();
        } else if (ret == -1) {
          if (errno == EINTR || errno == EAGAIN)
            goto retry;
          throw new Exception("wtf select");
        } else {
          return;
        }
      }
    } else static assert(0, "not supported");
    }
  }
  return Loop(duration).loopStream!void;
}

/// takes the first n values from a stream or until cancelled
auto take(Stream)(Stream stream, size_t n) {
  struct TakeOp(DG, Receiver) {
    import concurrency.operations : withStopSource;
    import std.traits : ReturnType, Parameters;
    alias ElementType = Stream.ElementType;
    alias StreamSender = ReturnType!(Stream.collect!(void delegate(ElementType t) nothrow @safe));
    alias SS = ReturnType!(withStopSource!StreamSender);
    alias Op = ReturnType!(SS.connect!Receiver);
    size_t n;
    DG dg;
    StopSource stopSource;
    Op op;
    private this(Stream stream, size_t n, DG dg, Receiver receiver) {
      stopSource = new StopSource();
      this.dg = dg;
      this.n = n;
      op = stream.collect(&item).withStopSource(stopSource).connect(receiver);
    }
    private void item(ElementType t) {
      dg(t);
      n--;
      if (n == 0)
        stopSource.stop();
    }
    void start() {
      op.start();
    }
  }
  struct TakeSender(DG) {
    alias Value = void;
    Stream stream;
    size_t n;
    DG dg;
    auto connect(Receiver)(Receiver receiver) {
      // what if we create a ValueSender with stream, n and dg?
      return TakeOp!(DG, Receiver)(stream, n, dg, receiver);
    }
  }
  struct TakeStream {
    alias ElementType = Stream.ElementType;
    Stream stream;
    size_t n;
    auto collect(DG)(DG dg) {
      return TakeSender!(DG)(stream, n, dg);
    }
  }
  return TakeStream(stream, n);
}

