package clashapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/sagernet/sing-box/adapter"

	"github.com/miekg/dns"
	"github.com/stretchr/testify/require"
)

type queryTestRouter struct {
	adapter.DNSRouter
	options   adapter.DNSQueryOptions
	called    bool
	cancelled bool
}

func (r *queryTestRouter) Exchange(ctx context.Context, msg *dns.Msg, opts adapter.DNSQueryOptions) (*dns.Msg, error) {
	r.called = true
	r.options = opts
	r.cancelled = ctx.Err() != nil
	return new(dns.Msg).SetReply(msg), nil
}

func TestQueryDNSSkipFakeIP(t *testing.T) {
	for _, tc := range []struct {
		query  string
		status int
		skip   bool
	}{
		{"", 200, false}, {"&skip-fake-ip=false", 200, false}, {"&skip-fake-ip=true", 200, true}, {"&skip-fake-ip=invalid", 400, false}, {"&skip-fake-ip=", 400, false},
	} {
		t.Run(tc.query, func(t *testing.T) {
			router := new(queryTestRouter)
			req := httptest.NewRequest("GET", "/query?name=example.com&type=A"+tc.query, nil)
			w := httptest.NewRecorder()
			dnsRouter(router).ServeHTTP(w, req)
			require.Equal(t, tc.status, w.Code)
			if tc.status != 200 {
				require.False(t, router.called)
				return
			}
			require.Equal(t, tc.skip, router.options.SkipFakeIP)
			var body map[string]any
			require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
			if tc.skip {
				require.Equal(t, true, body["SkipFakeIP"])
			} else {
				_, exists := body["SkipFakeIP"]
				require.False(t, exists)
			}
		})
	}
}

func TestQueryDNSRequestCancellation(t *testing.T) {
	router := new(queryTestRouter)
	req := httptest.NewRequest("GET", "/query?name=example.com", nil)
	ctx, cancel := context.WithCancel(req.Context())
	cancel()
	dnsRouter(router).ServeHTTP(httptest.NewRecorder(), req.WithContext(ctx))
	require.True(t, router.cancelled)
}
