package api

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	boxService "github.com/sagernet/sing-box/adapter/service"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"

	"github.com/stretchr/testify/require"
)

func TestSameListenAddress(t *testing.T) {
	listenOptions := func(address string, port uint16) option.ListenOptions {
		options := option.ListenOptions{ListenPort: port}
		if address != "" {
			addr := badoption.Addr(netip.MustParseAddr(address))
			options.Listen = &addr
		}
		return options
	}
	for _, testCase := range []struct {
		name     string
		options  option.ListenOptions
		address  string
		expected bool
	}{
		{"same loopback", listenOptions("127.0.0.1", 9090), "127.0.0.1:9090", true},
		{"default listen is loopback", listenOptions("", 9090), "127.0.0.1:9090", true},
		{"different port", listenOptions("127.0.0.1", 9090), "127.0.0.1:9091", false},
		{"different address", listenOptions("127.0.0.1", 9090), "192.168.1.1:9090", false},
		{"empty host matches unspecified", listenOptions("::", 9090), ":9090", true},
		{"empty host does not match loopback", listenOptions("127.0.0.1", 9090), ":9090", false},
		{"ipv4 and ipv6 unspecified", listenOptions("0.0.0.0", 9090), "[::]:9090", true},
		{"ipv4-mapped ipv6", listenOptions("127.0.0.1", 9090), "[::ffff:127.0.0.1]:9090", true},
		{"hostname is not merged", listenOptions("127.0.0.1", 9090), "localhost:9090", false},
		{"random port is not merged", listenOptions("127.0.0.1", 0), "127.0.0.1:0", false},
		{"invalid address", listenOptions("127.0.0.1", 9090), "127.0.0.1", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			require.Equal(t, testCase.expected, sameListenAddress(testCase.options, testCase.address))
		})
	}
}

func TestSharedListenerRouting(t *testing.T) {
	clashHandler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("X-Handler", "clash")
		writer.WriteHeader(http.StatusTeapot)
	})
	observabilityHandler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("X-Handler", "observability")
		writer.WriteHeader(http.StatusNoContent)
	})
	handler := newHTTPHandler(log.NewNOPFactory().NewLogger("api"), nil, option.APIServiceOptions{
		AccessControlAllowOrigin: []string{"https://api.example.com"},
	}, nil, observabilityHandler, clashHandler)

	serve := func(request *http.Request) *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	for _, path := range []string{"/", "/proxies", "/connections", "/logs", "/ui/", "/configs"} {
		response := serve(httptest.NewRequest(http.MethodGet, path, nil))
		require.Equal(t, "clash", response.Header().Get("X-Handler"), path)
	}

	response := serve(httptest.NewRequest(http.MethodGet, "/observability/v1/status", nil))
	require.Equal(t, "observability", response.Header().Get("X-Handler"))

	response = serve(httptest.NewRequest(http.MethodGet, "/dashboard/", nil))
	require.Equal(t, http.StatusNotFound, response.Code)
	require.Empty(t, response.Header().Get("X-Handler"))

	// gRPC-Web preflight carries no gRPC content type, it must be routed by path to the API CORS handler.
	request := httptest.NewRequest(http.MethodOptions, "/daemon.StartedService/GetVersion", nil)
	request.Header.Set("Origin", "https://api.example.com")
	request.Header.Set("Access-Control-Request-Method", http.MethodPost)
	request.Header.Set("Access-Control-Request-Headers", "content-type,x-grpc-web")
	response = serve(request)
	require.Empty(t, response.Header().Get("X-Handler"))
	require.Equal(t, "https://api.example.com", response.Header().Get("Access-Control-Allow-Origin"))

	// Clash preflights never reach the API CORS handler, so API origins do not leak into Clash API.
	request = httptest.NewRequest(http.MethodOptions, "/proxies/select", nil)
	request.Header.Set("Origin", "https://api.example.com")
	request.Header.Set("Access-Control-Request-Method", http.MethodPut)
	response = serve(request)
	require.Equal(t, "clash", response.Header().Get("X-Handler"))
}

type testClashServer struct {
	adapter.LifecycleService
	address       string
	secret        string
	listenerOwner string
}

func (s *testClashServer) ExternalController() string {
	return s.address
}

func (s *testClashServer) Secret() string {
	return s.secret
}

func (s *testClashServer) HTTPHandler() http.Handler {
	return http.NotFoundHandler()
}

func (s *testClashServer) SetListenerOwner(owner string) {
	s.listenerOwner = owner
}

func TestAttachClashServer(t *testing.T) {
	newService := func() *Service {
		return &Service{
			Adapter: boxService.NewAdapter(C.TypeAPI, "api"),
			options: option.APIServiceOptions{
				ListenOptions: option.ListenOptions{ListenPort: 9090},
				Secret:        "api-secret",
			},
		}
	}

	clashServer := &testClashServer{address: "127.0.0.1:9091", secret: "clash-secret"}
	apiService := newService()
	require.False(t, apiService.AttachClashServer(clashServer))
	require.Empty(t, clashServer.listenerOwner)
	require.Nil(t, apiService.clashServer)

	clashServer = &testClashServer{address: "127.0.0.1:9090", secret: "clash-secret"}
	apiService = newService()
	require.True(t, apiService.AttachClashServer(clashServer))
	require.Equal(t, "service/api[api]", clashServer.listenerOwner)
	require.Same(t, clashServer, apiService.clashServer)
}

func TestObservabilityAcceptsAnyConfiguredSecret(t *testing.T) {
	target := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	})
	for _, testCase := range []struct {
		name          string
		secrets       []string
		authorization string
		expected      int
	}{
		{"no secret", []string{"", ""}, "", http.StatusNoContent},
		{"both secrets without token", []string{"api-secret", "clash-secret"}, "", http.StatusUnauthorized},
		{"both secrets with wrong token", []string{"api-secret", "clash-secret"}, "Bearer wrong", http.StatusUnauthorized},
		{"both secrets with api token", []string{"api-secret", "clash-secret"}, "Bearer api-secret", http.StatusNoContent},
		{"both secrets with clash token", []string{"api-secret", "clash-secret"}, "Bearer clash-secret", http.StatusNoContent},
		{"only clash secret without token", []string{"", "clash-secret"}, "", http.StatusUnauthorized},
		{"only clash secret with empty token", []string{"", "clash-secret"}, "Bearer ", http.StatusUnauthorized},
		{"only clash secret with token", []string{"", "clash-secret"}, "Bearer clash-secret", http.StatusNoContent},
		{"only api secret with token", []string{"api-secret", ""}, "Bearer api-secret", http.StatusNoContent},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/status", nil)
			if testCase.authorization != "" {
				request.Header.Set("Authorization", testCase.authorization)
			}
			response := httptest.NewRecorder()
			authenticateObservability(target, testCase.secrets...).ServeHTTP(response, request)
			require.Equal(t, testCase.expected, response.Code)
		})
	}
}
