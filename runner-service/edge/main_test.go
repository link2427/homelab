package main

import (
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
	"testing"
)

func TestIdentityRequiresGrantAndMatchingSubject(t *testing.T) {
	profiles := map[string]profile{"jacob": {Subjects: []string{"user:jacob@example.test"}}, "agent": {Subjects: []string{"tag:runner-agent"}}}
	who := &apitype.WhoIsResponse{Node: &tailcfg.Node{}, UserProfile: &tailcfg.UserProfile{LoginName: "jacob@example.test"}}
	if _, ok := identity(who, profiles); ok {
		t.Fatal("identity without capability accepted")
	}
	who.CapMap = tailcfg.PeerCapMap{capability: []tailcfg.RawMessage{`{"identity":"jacob"}`}}
	if id, ok := identity(who, profiles); !ok || id != "jacob" {
		t.Fatal("authorized user rejected")
	}
	who.UserProfile.LoginName = "intruder@example.test"
	if _, ok := identity(who, profiles); ok {
		t.Fatal("wrong subject accepted")
	}
	who.UserProfile.LoginName = "jacob@example.test"
	who.Node.Tags = []string{"tag:unrelated"}
	if _, ok := identity(who, profiles); ok {
		t.Fatal("tagged device inherited enrolling user's authority")
	}
	who.Node.Tags = []string{"tag:runner-agent"}
	who.CapMap[capability] = []tailcfg.RawMessage{`{"identity":"agent"}`}
	if id, ok := identity(who, profiles); !ok || id != "agent" {
		t.Fatal("authorized tagged agent rejected")
	}
	if _, ok := identity(nil, profiles); ok {
		t.Fatal("nil identity accepted")
	}
}
