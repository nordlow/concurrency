module ut.concurrency.nursery;

import concurrency;
import concurrency.sender;
import concurrency.thread;
import concurrency.operations;
import concurrency.nursery;
import concurrency.stoptoken;
import unit_threaded;

@("run.value")
@safe unittest {
  auto nursery = new shared Nursery();
  nursery.run(ValueSender!(int)(5));
  nursery.sync_wait().shouldEqual(true);
  nursery.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.exception")
@safe unittest {
  auto nursery = new shared Nursery();
  nursery.run(ThrowingSender());
  nursery.sync_wait().shouldThrow();
  nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.value.then")
@safe unittest {
  auto nursery = new shared Nursery();
  shared(int) global;
  nursery.run(ValueSender!(int)(5).then((int c) shared => global = c));
  global.shouldEqual(0);
  nursery.sync_wait().shouldEqual(true);
  global.shouldEqual(5);
}

@("run.thread.run")
@safe unittest {
  auto nursery = new shared Nursery();
  shared(int) global;
  nursery.run(ThreadSender().then(() shared @safe {
        nursery.run(ValueSender!(int)(5).then((int c) shared @safe {
              global = c;
            }));
      }));
  global.shouldEqual(0);
  nursery.sync_wait().shouldEqual(true);
  global.shouldEqual(5);
  nursery.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.thread.stop.internal")
@safe unittest {
  auto nursery = new shared Nursery();
  nursery.run(ThreadSender().then(() shared @safe => nursery.stop()));
  nursery.sync_wait().shouldEqual(false);
  nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.thread.stop.external")
@trusted unittest {
  auto nursery = new shared Nursery();
  auto stopSource = new shared StopSource();
  nursery.run(ThreadSender().then(() shared @safe => stopSource.stop()));
  nursery.sync_wait(cast(StopSource)stopSource).shouldEqual(false);
  nursery.getStopToken().isStopRequested().shouldBeTrue();
  stopSource.isStopRequested().shouldBeTrue();
}

@("run.thread.stop.internal.sibling")
@safe unittest {
  import core.thread : Thread;
  auto nursery = new shared Nursery();
  auto thread1 = ThreadSender().then(() shared @trusted {
      auto token = nursery.getStopToken();
      while (!token.isStopRequested()) Thread.yield();
    });
  auto thread2 = ThreadSender().then(() shared @safe => nursery.stop());
  nursery.run(thread1);
  nursery.run(thread2);
  nursery.sync_wait().shouldEqual(false);
  nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("run.nested")
@safe unittest {
  auto nursery1 = new shared Nursery();
  auto nursery2 = new shared Nursery();
  shared(int) global;
  nursery1.run(nursery2);
  nursery2.run(ValueSender!(int)(99).then((int c) shared => global = c));
  global.shouldEqual(0);
  nursery1.sync_wait().shouldEqual(true);
  global.shouldEqual(99);
  nursery1.getStopToken().isStopRequested().shouldBeFalse();
  nursery2.getStopToken().isStopRequested().shouldBeFalse();
}

@("run.error")
@safe unittest {
  import core.thread : Thread;
  auto nursery = new shared Nursery();
  auto thread1 = ThreadSender().then(() shared @trusted {
      auto token = nursery.getStopToken();
      while (!token.isStopRequested()) Thread.yield();
    });
  auto thread2 = ThreadSender().withStopToken((StopToken token) shared @trusted {
      while (!token.isStopRequested()) Thread.yield();
    });
  auto thread3 = ThreadSender().then(() shared @safe { throw new Exception("Error should stop everyone"); });
  nursery.run(thread1);
  nursery.run(thread2);
  nursery.run(thread3);
  nursery.getStopToken().isStopRequested().shouldBeFalse();
  nursery.sync_wait().shouldThrow();
  nursery.getStopToken().isStopRequested().shouldBeTrue();
}

@("withStopSource.1")
unittest {
  import core.thread : Thread;
  auto stopSource = new StopSource();
  auto nursery = new shared Nursery();

  auto thread1 = ThreadSender()
    .withStopToken((StopToken stopToken) shared {
          while(!stopToken.isStopRequested)
            Thread.yield();
      })
    .withStopSource(stopSource);

  // stop via the source
  auto stopper = ValueSender!StopSource(stopSource).then((StopSource stopSource) shared => stopSource.stop());

  nursery.run(thread1);
  nursery.run(stopper);

  nursery.sync_wait().shouldEqual(true);
}

@("withStopSource.2")
unittest {
  import core.thread : Thread;
  auto stopSource = new StopSource();
  auto nursery = new shared Nursery();

  auto thread1 = ThreadSender()
    .withStopToken((StopToken stopToken) shared {
        while(!stopToken.isStopRequested)
          Thread.yield();
      })
    .withStopSource(stopSource);

  // stop via the nursery
  auto stopper = ValueSender!(shared Nursery)(nursery).then((shared Nursery nursery) shared => nursery.stop());

  nursery.run(thread1);
  nursery.run(stopper);

  nursery.sync_wait().shouldEqual(false);
}

@("nothrow")
@safe unittest {
  auto nursery = new shared Nursery();
  (() nothrow => nursery.run(ValueSender!int(21)))();
}
