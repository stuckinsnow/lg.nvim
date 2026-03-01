package transport

import (
	"bufio"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"

	"lg-lsp/internal/lsptype"
)

var (
	mu     sync.Mutex
	Writer *bufio.Writer
)

func Send(msg lsptype.Message) {
	data, _ := json.Marshal(msg)
	mu.Lock()
	fmt.Fprintf(Writer, "Content-Length: %d\r\n\r\n%s", len(data), data)
	Writer.Flush()
	mu.Unlock()
}

func Read(reader *bufio.Reader) ([]byte, error) {
	var contentLen int
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if strings.HasPrefix(line, "Content-Length:") {
			n, _ := strconv.Atoi(strings.TrimSpace(line[15:]))
			contentLen = n
		}
	}
	if contentLen == 0 {
		return nil, fmt.Errorf("no content-length")
	}
	body := make([]byte, contentLen)
	n := 0
	for n < contentLen {
		r, err := reader.Read(body[n:])
		if err != nil {
			return nil, err
		}
		n += r
	}
	return body, nil
}
