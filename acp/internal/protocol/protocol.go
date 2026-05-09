package protocol

import "encoding/json"

// --- Builders ---

func InitializeRequest(id int, clientName string) Message {
	params, _ := json.Marshal(map[string]any{
		"protocolVersion":    1,
		// writeTextFile:true routes the agent's file writes through lg's
		// handleFSWrite so we can enforce mode-based write policies (e.g.
		// block direct writes in reviewer/lg modes, forcing paint_edit).
		"clientCapabilities": map[string]any{"fs": map[string]any{"readTextFile": true, "writeTextFile": true}},
		"clientInfo":         map[string]any{"name": clientName, "version": "2.0.0"},
	})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "initialize", Params: params}
}

func SessionNewRequest(id int, cwd string, mcpServers map[string]any) Message {
	params := map[string]any{"cwd": cwd}
	if len(mcpServers) > 0 {
		params["mcpServers"] = mcpServers
	} else {
		params["mcpServers"] = []any{}
	}
	data, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/new", Params: data}
}

func SessionPromptRequest(id int, sessionID string, prompt json.RawMessage) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "prompt": prompt})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/prompt", Params: params}
}

func SessionSetModeRequest(id int, sessionID, modeID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "modeId": modeID})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_mode", Params: params}
}

func SessionSetModelRequest(id int, sessionID, modelID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "modelId": modelID})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_model", Params: params}
}

func SessionCancelNotification(sessionID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID})
	return Message{JSONRPC: "2.0", Method: "session/cancel", Params: params}
}

func SessionListRequest(id int, cwd string) Message {
	params, _ := json.Marshal(map[string]any{"cwd": cwd})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/list", Params: params}
}

func SessionLoadRequest(id int, sessionID, cwd string, mcpServers map[string]any) Message {
	params := map[string]any{"sessionId": sessionID, "cwd": cwd}
	if len(mcpServers) > 0 {
		params["mcpServers"] = mcpServers
	} else {
		params["mcpServers"] = []any{}
	}
	data, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/load", Params: data}
}

func PermissionResponse(id *RPCID, optionID string) Message {
	result, _ := json.Marshal(map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": optionID}})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

func FSReadResponse(id *RPCID, content string) Message {
	result, _ := json.Marshal(map[string]any{"content": content})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

func FSWriteResponse(id *RPCID) Message {
	return Message{JSONRPC: "2.0", ID: id, Result: json.RawMessage("null")}
}

// ErrorResponse builds a JSON-RPC error response (used to reject fs/write etc.).
func ErrorResponse(id *RPCID, code int, message string) Message {
	return Message{JSONRPC: "2.0", ID: id, Error: &RPCError{Code: code, Message: message}}
}

func CommandExecuteRequest(id int, sessionID, command string, args map[string]any) Message {
	cmd := command
	if len(cmd) > 0 && cmd[0] == '/' {
		cmd = cmd[1:]
	}
	if args == nil {
		args = map[string]any{}
	}
	params, _ := json.Marshal(map[string]any{
		"sessionId": sessionID,
		"command": map[string]any{
			"command": cmd,
			"args":    args,
		},
	})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "_kiro.dev/commands/execute", Params: params}
}

// GenericRequest builds an arbitrary JSON-RPC request with the given method and params.
func GenericRequest(id int, method string, params map[string]any) Message {
	if params == nil {
		params = map[string]any{}
	}
	p, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: method, Params: p}
}
