package protocol

import (
	"encoding/json"
	"fmt"
	"sort"
)

// --- Builders ---

func InitializeRequest(id int, clientName string) Message {
	params, _ := json.Marshal(map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{"fs": map[string]any{"readTextFile": true, "writeTextFile": false}},
		"clientInfo":         map[string]any{"name": clientName, "version": "2.0.0"},
	})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "initialize", Params: params}
}

func AuthenticateRequest(id int, methodID string) Message {
	params, _ := json.Marshal(map[string]any{"methodId": methodID})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "authenticate", Params: params}
}

func SessionNewRequest(id int, cwd string, mcpServers any) Message {
	params := map[string]any{"cwd": cwd, "mcpServers": mcpServersParam(mcpServers)}
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

func SessionSetConfigOptionRequest(id int, sessionID, configID, value string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID, "configId": configID, "value": value})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/set_config_option", Params: params}
}

func SessionCancelNotification(sessionID string) Message {
	params, _ := json.Marshal(map[string]any{"sessionId": sessionID})
	return Message{JSONRPC: "2.0", Method: "session/cancel", Params: params}
}

func SessionListRequest(id int, cwd string) Message {
	params, _ := json.Marshal(map[string]any{"cwd": cwd})
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/list", Params: params}
}

func SessionLoadRequest(id int, sessionID, cwd string, mcpServers any) Message {
	params := map[string]any{"sessionId": sessionID, "cwd": cwd, "mcpServers": mcpServersParam(mcpServers)}
	data, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: "session/load", Params: data}
}

func PermissionResponse(id *RPCID, optionID string) Message {
	result, _ := json.Marshal(map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": optionID}})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

// MethodNotFoundResponse answers an agent-to-client request lg doesn't handle,
// so the agent never waits on it.
func MethodNotFoundResponse(id *RPCID, method string) Message {
	return Message{JSONRPC: "2.0", ID: id, Error: &RPCError{Code: -32601, Message: "Method not found: " + method}}
}

func FSReadResponse(id *RPCID, content string) Message {
	result, _ := json.Marshal(map[string]any{"content": content})
	return Message{JSONRPC: "2.0", ID: id, Result: result}
}

// GenericRequest builds an arbitrary JSON-RPC request with the given method and params.
func GenericRequest(id int, method string, params map[string]any) Message {
	if params == nil {
		params = map[string]any{}
	}
	p, _ := json.Marshal(params)
	return Message{JSONRPC: "2.0", ID: NewID(id), Method: method, Params: p}
}

// mcpServersParam sends an empty list when no servers are configured.
func mcpServersParam(servers any) any {
	switch v := servers.(type) {
	case nil:
		return []any{}
	case map[string]any:
		if len(v) == 0 {
			return []any{}
		}
	case []any:
		if len(v) == 0 {
			return []any{}
		}
	}
	return servers
}

// ACPMCPServers converts lg's {name: {command, args, env}} map into the ACP
// session/new format: [{name, command, args, env: [{name, value}]}]. Sorted
// by name so requests are deterministic.
func ACPMCPServers(servers map[string]any) []any {
	names := make([]string, 0, len(servers))
	for name := range servers {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]any, 0, len(servers))
	for _, name := range names {
		cfg, _ := servers[name].(map[string]any)
		command, _ := cfg["command"].(string)
		if command == "" {
			continue
		}
		args := []any{}
		if a, ok := cfg["args"].([]any); ok {
			args = a
		}
		envMap, _ := cfg["env"].(map[string]any)
		envKeys := make([]string, 0, len(envMap))
		for k := range envMap {
			envKeys = append(envKeys, k)
		}
		sort.Strings(envKeys)
		env := make([]any, 0, len(envMap))
		for _, k := range envKeys {
			env = append(env, map[string]any{"name": k, "value": fmt.Sprint(envMap[k])})
		}
		out = append(out, map[string]any{"name": name, "command": command, "args": args, "env": env})
	}
	return out
}
