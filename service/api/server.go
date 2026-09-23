package api

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"strconv"

	"github.com/sagernet/sing-box/adapter"
	boxService "github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/common/listener"
	"github.com/sagernet/sing-box/common/tls"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/daemon"
	"github.com/sagernet/sing-box/experimental/observability"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	N "github.com/sagernet/sing/common/network"
	aTLS "github.com/sagernet/sing/common/tls"
	"github.com/sagernet/sing/service"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c" //nolint:staticcheck
	"google.golang.org/grpc"
)

func RegisterService(registry *boxService.Registry) {
	boxService.Register[option.APIServiceOptions](registry, C.TypeAPI, NewService)
}

type Service struct {
	boxService.Adapter
	ctx            context.Context
	cancel         context.CancelFunc
	logger         log.ContextLogger
	options        option.APIServiceOptions
	listener       *listener.Listener
	tlsConfig      tls.ServerConfig
	startedService *daemon.StartedService
	grpcServer     *grpc.Server
	httpServer     *http.Server
	dashboard      *dashboard
	clashServer    adapter.ClashHTTPServer
}

func NewService(ctx context.Context, logger log.ContextLogger, tag string, options option.APIServiceOptions) (adapter.Service, error) {
	ctx, cancel := context.WithCancel(ctx)
	s := &Service{
		Adapter: boxService.NewAdapter(C.TypeAPI, tag),
		ctx:     ctx,
		cancel:  cancel,
		logger:  logger,
		options: options,
		listener: listener.New(listener.Options{
			Context: ctx,
			Logger:  logger,
			Network: []string{N.NetworkTCP},
			Listen:  options.ListenOptions,
		}),
	}
	if options.TLS != nil {
		tlsConfig, err := tls.NewServer(ctx, logger, common.PtrValueOrDefault(options.TLS))
		if err != nil {
			cancel()
			return nil, err
		}
		s.tlsConfig = tlsConfig
	}
	if options.Dashboard != nil && options.Dashboard.Enabled {
		s.dashboard = newDashboard(ctx, logger, *options.Dashboard)
	}
	return s, nil
}

func (s *Service) Start(stage adapter.StartStage) error {
	if stage != adapter.StartStateStarted {
		return nil
	}
	s.startedService = daemon.NewAttachedService(s.ctx)
	s.grpcServer = daemon.NewServer(s.startedService, s.options.Secret)
	secrets := []string{s.options.Secret}
	var clashHandler http.Handler
	if s.clashServer != nil {
		secrets = append(secrets, s.clashServer.Secret())
		clashHandler = s.clashServer.HTTPHandler()
	}
	var observabilityHandler http.Handler
	if observabilityService := service.FromContext[observability.Service](s.ctx); observabilityService != nil {
		observabilityHandler = authenticateObservability(http.StripPrefix(observabilityRoutePrefix, observabilityService.Handler()), secrets...)
	}
	if s.dashboard != nil {
		err := s.dashboard.start()
		if err != nil {
			return E.Cause(err, "start dashboard")
		}
	}
	s.httpServer = &http.Server{
		//nolint:staticcheck
		Handler: h2c.NewHandler(newHTTPHandler(s.logger, s.grpcServer, s.options, s.dashboard, observabilityHandler, clashHandler), new(http2.Server)),
		BaseContext: func(net.Listener) context.Context {
			return s.ctx
		},
	}
	if s.tlsConfig != nil {
		err := s.tlsConfig.Start()
		if err != nil {
			return E.Cause(err, "create TLS config")
		}
		if !common.Contains(s.tlsConfig.NextProtos(), http2.NextProtoTLS) {
			s.tlsConfig.SetNextProtos(append([]string{http2.NextProtoTLS}, s.tlsConfig.NextProtos()...))
		}
		if !common.Contains(s.tlsConfig.NextProtos(), "http/1.1") {
			s.tlsConfig.SetNextProtos(append(s.tlsConfig.NextProtos(), "http/1.1"))
		}
	}
	tcpListener, err := s.listener.ListenTCP()
	if err != nil {
		return err
	}
	if s.tlsConfig != nil {
		tcpListener = aTLS.NewListener(tcpListener, s.tlsConfig)
	}
	if s.clashServer != nil {
		s.logger.Info("serving clash api on shared listener")
	}
	go func() {
		serveErr := s.httpServer.Serve(tcpListener)
		if serveErr != nil && s.ctx.Err() == nil {
			s.logger.Error("serve error: ", serveErr)
		}
	}()
	return nil
}

// AttachClashServer serves the Clash API on this service's listener when both
// are configured with the same listen address. Each side keeps its own secret
// and CORS options.
func (s *Service) AttachClashServer(server adapter.ClashHTTPServer) bool {
	if !sameListenAddress(s.options.ListenOptions, server.ExternalController()) {
		return false
	}
	s.clashServer = server
	server.SetListenerOwner("service/" + s.Type() + "[" + s.Tag() + "]")
	return true
}

func sameListenAddress(options option.ListenOptions, address string) bool {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 || uint16(port) != options.ListenPort {
		return false
	}
	listenAddr := options.Listen.Build(netip.AddrFrom4([4]byte{127, 0, 0, 1})).Unmap()
	if host == "" {
		return listenAddr.IsUnspecified()
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	return addr == listenAddr || addr.IsUnspecified() && listenAddr.IsUnspecified()
}

// authenticateObservability accepts any configured secret; empty secrets are
// ignored, and no authentication is required if none is configured.
func authenticateObservability(next http.Handler, secrets ...string) http.Handler {
	secrets = common.Filter(secrets, func(it string) bool {
		return it != ""
	})
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		authorization := request.Header.Get("Authorization")
		if len(secrets) == 0 || common.Any(secrets, func(it string) bool {
			return authorization == "Bearer "+it
		}) {
			next.ServeHTTP(writer, request)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusUnauthorized)
		_, _ = writer.Write([]byte("{\"error\":{\"code\":\"unauthorized\",\"message\":\"unauthorized\"}}\n"))
	})
}

func (s *Service) Close() error {
	s.cancel()
	if s.dashboard != nil {
		s.dashboard.close()
	}
	if s.httpServer != nil {
		s.httpServer.Close()
	}
	if s.grpcServer != nil {
		s.grpcServer.Stop()
	}
	if s.startedService != nil {
		s.startedService.Close()
	}
	return common.Close(
		common.PtrOrNil(s.listener),
		s.tlsConfig,
	)
}
