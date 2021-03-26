module ut.concurrency.stream;

import concurrency.stream;
import concurrency;
import unit_threaded;

// TODO: it would be good if we can get the Sender .collect returns to be scoped if the delegates are.

@("arrayStream")
unittest {
  int p = 0;
  [1,2,3].arrayStream().collect((int t){ p += t; }).sync_wait();
  p.should == 6;
}

@("timerStream")
unittest {
  import concurrency.stoptoken;
  import concurrency.operations : withStopSource, whenAll, via;
  import concurrency.thread : ThreadSender;
  import core.time : msecs;
  int s = 0, f = 0;
  auto source = new StopSource();
  auto slow = 10.msecs.intervalStream().collect((){ s += 1; source.stop(); }).withStopSource(source).via(ThreadSender());
  auto fast = 3.msecs.intervalStream().collect((){ f += 1; });
  whenAll(slow, fast).sync_wait(source);
  s.should == 1;
  f.shouldBeGreaterThan(1);
}


@("infiniteStream.stop")
unittest {
  import concurrency.stoptoken;
  import concurrency.operations : withStopSource;
  int g = 0;
  auto source = new StopSource();
  infiniteStream(5).collect((int n){
      if (g < 14)
        g += n;
      else
        source.stop();
    })
    .withStopSource(source).sync_wait();
  g.should == 15;
};

@("infiniteStream.take")
unittest {
  import concurrency.stoptoken;
  int g = 0;
  infiniteStream(4).take(5).collect((int n) => g += n).sync_wait();
  g.should == 20;
}

@("iotaStream")
unittest {
  import concurrency.stoptoken;
  int g = 0;
  iotaStream(0, 5).collect((int n) => cast(void)(g += n)).sync_wait();
  g.should == 10;
}

@("loopStream")
unittest {
  struct Loop {
    size_t b,e;
    void loop(DG, StopToken)(DG emit, StopToken stopToken) {
      foreach(i; b..e)
        emit(i);
    }
  }
  int g = 0;
  Loop(0,4).loopStream!size_t.collect((size_t n) => g += n).sync_wait();
  g.should == 6;
}

class Broker {
  import core.sync.mutex : Mutex;
  struct Message {
    int id;
    int payload;
  }
  alias Callback = void delegate(Message);
  private {
    Callback[int] callbacks;
    Mutex mutex;
    auto lock() shared @trusted {
      import concurrency.utils : SharedGuard;
      return SharedGuard!Broker.acquire(this, cast()mutex);
    }
  }
  this() shared {
    mutex = new shared Mutex();
  }
  void startSubscription(Callback cb, int id) shared @safe {
    with(lock) {
      callbacks[id] = cb;
    }
  }
  void removeSubscription(int id) shared @safe nothrow {
    with(lock) {
      callbacks.remove(id);
    }
  }
  void emit(Message msg) shared {
    with(lock) {
      if (auto cb = msg.id in callbacks) {
        (*cb)(msg);
      }
    }
  }
  auto messageStream(int id) shared {
    static struct StartStop {
      shared Broker broker;
      int id;
      void start(DG, StopToken)(DG emit, StopToken stopToken) {
        broker.startSubscription(emit, id);
      }
      void stop() {
        broker.removeSubscription(id);
      }
    }
    return StartStop(this, id).startStopStream!Message;
  }
}

@("Stream.broker")
unittest {
  import concurrency.operations : via, race;
  import concurrency.thread : ThreadSender;
  auto broker = new shared Broker();
  auto emitter = iotaStream(0, 5).collect((int n) {
      broker.emit(Broker.Message(n % 2,n));
    }).via(ThreadSender());
  int n0,n1;
  auto stream0 = broker.messageStream(0).collect((Broker.Message m) {
      n0 += m.payload;
    });
  auto stream1 = broker.messageStream(1).collect((Broker.Message m) {
      n1 += m.payload;
    });
  race(stream0, stream1, emitter).sync_wait();
  n0.should == 6;
  n1.should == 4;
}
