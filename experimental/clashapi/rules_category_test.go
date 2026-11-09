package clashapi

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/sagernet/sing-box/adapter"
)

type categoryTestRule struct {
	adapter.Rule
}

func (categoryTestRule) Type() string               { return "default" }
func (categoryTestRule) String() string             { return "example.com" }
func (categoryTestRule) Action() adapter.RuleAction { return categoryTestAction{} }
func (categoryTestRule) Disabled() bool             { return false }
func (categoryTestRule) UUID() string               { return "test-rule" }

type categoryTestAction struct{ adapter.RuleAction }

func (categoryTestAction) String() string { return "reject" }

type categoryTestRouter struct {
	adapter.Router
}

func (categoryTestRouter) Rules() []adapter.Rule { return []adapter.Rule{categoryTestRule{}} }

type categoryTestDNSRouter struct {
	adapter.DNSRouter
}

func (categoryTestDNSRouter) Rules() []adapter.DNSRule {
	return []adapter.DNSRule{categoryTestDNSRule{}}
}

type categoryTestDNSRule struct {
	categoryTestRule
	adapter.DNSRule
}

func (categoryTestDNSRule) Type() string               { return "default" }
func (categoryTestDNSRule) String() string             { return "example.com" }
func (categoryTestDNSRule) Action() adapter.RuleAction { return categoryTestAction{} }
func (categoryTestDNSRule) Disabled() bool             { return false }
func (categoryTestDNSRule) UUID() string               { return "dns-rule" }

func TestRulesCategory(t *testing.T) {
	response := httptest.NewRecorder()
	ruleRouter(categoryTestRouter{}, categoryTestDNSRouter{}).ServeHTTP(response, httptest.NewRequest("GET", "/", nil))
	if response.Code != 200 {
		t.Fatalf("status: %d", response.Code)
	}
	var result struct {
		Rules []map[string]any `json:"rules"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Rules) != 2 {
		t.Fatalf("rules: %v", result.Rules)
	}
	for i, category := range []string{"dns", "route"} {
		if result.Rules[i]["category"] != category {
			t.Fatalf("rule %d: %v", i, result.Rules[i])
		}
		if result.Rules[i]["payload"] != "example.com" {
			t.Fatalf("payload: %v", result.Rules[i])
		}
	}
}
