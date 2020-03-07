all: build restart

run:
	overmind s

stop:
	overmind k

restart:
	overmind r web worker

build:
	crystal build src/server.cr -o bin/server
	crystal build src/worker.cr -o bin/worker
	crystal build src/relayctl.cr -o bin/relayctl

release:
	crystal build --release src/server.cr -o bin/server
	crystal build --release src/worker.cr -o bin/worker
	crystal build --release src/relayctl.cr -o bin/relayctl
	tar zcvf bin/selective-relay.tar.gz bin/server bin/worker bin/relayctl
