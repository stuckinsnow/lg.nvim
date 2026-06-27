package protocol

import (
	"encoding/json"
	"testing"
)

// opencode 1.17+ returns an empty models.availableModels and puts the model
// list in configOptions instead.
func TestParseModelsInfoOpencodeConfigOptions(t *testing.T) {
	raw := json.RawMessage(`{
		"sessionId": "ses_x",
		"models": {"currentModelId": null, "availableModels": []},
		"configOptions": [
			{"id": "model", "name": "Model", "type": "select",
			 "currentValue": "opencode/big-pickle",
			 "options": [
				{"value": "opencode/big-pickle", "name": "OpenCode Zen/Big Pickle"},
				{"value": "opencode/deepseek-v4-flash-free", "name": "OpenCode Zen/DeepSeek V4 Flash Free"}
			 ]}
		]
	}`)
	mi := ParseModelsInfo(raw)
	if mi == nil {
		t.Fatal("expected models info, got nil")
	}
	if mi.CurrentModelID != "opencode/big-pickle" {
		t.Fatalf("currentModelId = %q, want opencode/big-pickle", mi.CurrentModelID)
	}
	if len(mi.AvailableModels) != 2 {
		t.Fatalf("got %d models, want 2", len(mi.AvailableModels))
	}
	if mi.AvailableModels[1].ModelID != "opencode/deepseek-v4-flash-free" {
		t.Fatalf("model[1] = %q", mi.AvailableModels[1].ModelID)
	}
	if mi.AvailableModels[0].Name != "OpenCode Zen/Big Pickle" {
		t.Fatalf("model[0].Name = %q", mi.AvailableModels[0].Name)
	}
}

// kiro returns the standard availableModels; configOptions fallback must not
// override it.
func TestParseModelsInfoKiroAvailableModels(t *testing.T) {
	raw := json.RawMessage(`{
		"sessionId": "ses_y",
		"models": {"currentModelId": "claude-sonnet-4-6",
			"availableModels": [{"modelId": "claude-sonnet-4-6"}, {"modelId": "claude-haiku-4-5"}]}
	}`)
	mi := ParseModelsInfo(raw)
	if mi == nil {
		t.Fatal("expected models info, got nil")
	}
	if mi.CurrentModelID != "claude-sonnet-4-6" {
		t.Fatalf("currentModelId = %q", mi.CurrentModelID)
	}
	if len(mi.AvailableModels) != 2 {
		t.Fatalf("got %d models, want 2", len(mi.AvailableModels))
	}
}

func TestParseModelsInfoEmpty(t *testing.T) {
	if ParseModelsInfo(nil) != nil {
		t.Fatal("nil input should return nil")
	}
	if mi := ParseModelsInfo(json.RawMessage(`{"sessionId":"z"}`)); mi != nil {
		t.Fatalf("no models/configOptions should return nil, got %+v", mi)
	}
}
