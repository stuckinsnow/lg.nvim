#!/bin/bash
# Send a test hint to the running lg-lsp via its socket
# Usage: ./test_hint.sh /path/to/file.lua [line]

FILE="${1:-$(pwd)/lua/lg/init.lua}"
LINE="${2:-27}"

python3 -c "
import socket, json, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/dev/shm/lg-hint.sock')
msg = json.dumps({
    'method': 'set_hints',
    'hints': [
        {'file': '$FILE', 'line': $LINE, 'match': 'lg_hint_ns', 'message': 'Test hint: this variable could be local to the block', 'severity': 'info'},
        {'file': '$FILE', 'line': $((LINE + 1)), 'match': 'executable', 'message': 'Test hint: consider caching this result', 'severity': 'warning'},
    ]
})
s.sendall((msg + '\n').encode())
resp = s.recv(1024)
print(resp.decode().strip())
s.close()
"
