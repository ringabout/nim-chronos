import ../chronos

var servers: seq[StreamServer]
for _ in 0..<250:
    servers.add(createStreamServer(initTAddress("0.0.0.0:0")))
proc acceptor(server: StreamServer) {.async.} =
    while true:
        discard await server.accept()
var accepts: seq[Future[void]]
for s in servers:
    accepts.add(acceptor(s))
waitFor(sleepAsync 1.seconds)

var futs: seq[Future[void]]
for acc in accepts:
    futs.add(acc.cancelAndWait())
for s in servers:
    s.stop()
    futs.add(s.closeWait())
waitFor allFutures(futs)
echo "closed"
waitFor sleepAsync(1.seconds)