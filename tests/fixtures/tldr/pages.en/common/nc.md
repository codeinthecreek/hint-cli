# nc

> Fake netcat page for tests.

- Connect to a [t]arget listener on a port and send it a file:

`nc {{host}} {{port}} < {{path/to/file}}`

- Start a [l]istener on a port:

`nc {{[-l|--listen]}} {{[-p|--port]}} {{port}}`

- Scan the ports of a host with either protocol:

`nc {{[-z|--zero]}} {{--tcp|--udp}} {{host}} {{1-1000}}`
