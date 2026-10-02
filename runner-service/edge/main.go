// Vulcan's only caller-facing listener is a tsnet TLS listener. Never use Funnel.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tsnet"
)

const capability = "jacob-neel.dev/cap/runner"

var safeID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,40}$`)

type profile struct {
	Subjects []string `json:"subjects"`
}

func identity(who *apitype.WhoIsResponse, profiles map[string]profile) (string, bool) {
	if who == nil || who.Node == nil {
		return "", false
	}
	subjects := []string{}
	// Tagged nodes belong to the device, not the user who originally enrolled it.
	if len(who.Node.Tags) > 0 {
		subjects = append(subjects, who.Node.Tags...)
		subjects = append(subjects, "node:"+string(who.Node.StableID))
	} else if who.UserProfile != nil {
		subjects = append(subjects, "user:"+who.UserProfile.LoginName)
	}
	selected := ""
	for _, raw := range who.CapMap[capability] {
		var grant struct {
			Identity string `json:"identity"`
		}
		if json.Unmarshal([]byte(raw), &grant) != nil || !safeID.MatchString(grant.Identity) {
			continue
		}
		policy, ok := profiles[grant.Identity]
		if !ok {
			continue
		}
		for _, allowed := range policy.Subjects {
			for _, actual := range subjects {
				if actual == allowed {
					if selected != "" && selected != grant.Identity {
						return "", false
					}
					selected = grant.Identity
				}
			}
		}
	}
	return selected, selected != ""
}

func main() {
	raw, err := os.ReadFile(os.Getenv("RUNNER_CONFIG"))
	if err != nil {
		log.Fatal(err)
	}
	var config struct {
		Profiles map[string]profile `json:"profiles"`
	}
	if err = json.Unmarshal(raw, &config); err != nil {
		log.Fatal(err)
	}
	apiURL, _ := url.Parse("http://127.0.0.1:8000")
	storeURL, err := url.Parse(os.Getenv("S3_ENDPOINT"))
	if err != nil {
		log.Fatal(err)
	}
	api := httputil.NewSingleHostReverseProxy(apiURL)
	store := httputil.NewSingleHostReverseProxy(storeURL)
	// Preserve the signed external Host when forwarding a pre-signed S3 URL.
	store.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		http.Error(w, "artifact store unavailable", 502)
	}
	api.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) { http.Error(w, "runner unavailable", 502) }
	ts := &tsnet.Server{Hostname: "olympus-vulcan", Dir: "/state", AuthKey: os.Getenv("TS_AUTHKEY")}
	defer ts.Close()
	local, err := ts.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	listener, err := ts.ListenTLS("tcp", ":443")
	if err != nil {
		log.Fatal(err)
	}
	// Cluster listener serves health/metrics only; it cannot proxy API or artifact paths.
	monitor := http.NewServeMux()
	monitor.Handle("GET /healthz", api)
	monitor.Handle("GET /metrics", api)
	go func() {
		log.Fatal((&http.Server{Addr: ":9000", Handler: monitor, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
	}()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		public, err := url.Parse(os.Getenv("PUBLIC_URL"))
		if err != nil || r.Host != public.Host || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != public.String()) {
			http.Error(w, "invalid host or origin", 403)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		who, err := local.WhoIs(ctx, r.RemoteAddr)
		cancel()
		if err != nil {
			http.Error(w, "Tailscale identity required", 401)
			return
		}
		id, ok := identity(who, config.Profiles)
		if !ok {
			http.Error(w, "runner grant required", 403)
			return
		}
		r.Header.Del("X-Runner-Identity")
		r.Header.Set("X-Runner-Identity", id)
		r.Header.Del("Authorization")
		r.Header.Del("Forwarded")
		r.Header.Del("X-Forwarded-Host")
		r.Header.Del("X-Forwarded-Proto")
		r.Header.Del("X-Forwarded-For")
		if strings.HasPrefix(r.URL.Path, "/vulcan/") {
			if !strings.HasPrefix(r.URL.Path, "/vulcan/inputs/"+id+"/") && !strings.HasPrefix(r.URL.Path, "/vulcan/jobs/"+id+"/") {
				http.Error(w, "artifact belongs to another identity", 403)
				return
			}
			if r.Method != "GET" && r.Method != "PUT" && r.Method != "HEAD" {
				http.Error(w, "method not allowed", 405)
				return
			}
			// S3 verifies signed method, path, expiry and (for uploads) size.
			if r.URL.Query().Get("X-Amz-Signature") == "" {
				http.Error(w, "signed artifact URL required", 403)
				return
			}
			store.ServeHTTP(w, r)
			return
		}
		api.ServeHTTP(w, r)
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	log.Fatal(server.Serve(listener))
}
