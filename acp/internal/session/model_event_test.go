package session

import (
	"lg-acp/internal/protocol"
	"testing"
)

func TestChangedModel(t *testing.T) {
	update := protocol.SessionUpdate{
		SessionUpdate: "config_option_update",
		ConfigOptions: []protocol.ConfigOption{
			{ID: "mode", CurrentValue: "lg-oneshot"},
			{ID: "model", CurrentValue: "github-copilot/auto"},
		},
	}

	if got := changedModel(update); got != "github-copilot/auto" {
		t.Fatalf("changedModel() = %q, want %q", got, "github-copilot/auto")
	}
}

func TestChangedModelIgnoresOtherUpdates(t *testing.T) {
	update := protocol.SessionUpdate{
		SessionUpdate: "config_option_update",
		ConfigOptions: []protocol.ConfigOption{
			{ID: "mode", CurrentValue: "lg-oneshot"},
		},
	}

	if got := changedModel(update); got != "" {
		t.Fatalf("changedModel() = %q, want empty", got)
	}
}
