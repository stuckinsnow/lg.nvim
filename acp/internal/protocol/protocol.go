package protocol

import "encoding/json"

// --- Builders ---

func InitializeRequest(id int, clientName string) Message {
	params, _ := json.Marshal(map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{"fs": map[string]any{"readTextFile": true, "writeTextFile": false}},
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
