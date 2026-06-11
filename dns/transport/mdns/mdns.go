package mdns

import (
	"context"
	"net"
	"net/netip"
	"slices"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport/local/systemconfig"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/control"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/json/badoption"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
)

const (
	mdnsPort        = 5353
	mdnsClassTopBit = 1 << 15
	// mdnsTimeout is the hard cap of the response collection window.
	mdnsTimeout = time.Second
	// mdnsSettleTimeout is how long we keep collecting after the first answer
	// arrived, so answers from other responders/interfaces can be merged.
	mdnsSettleTimeout = 250 * time.Millisecond
	// mdnsHeadroom is reserved from the caller's deadline so the merged
	// response can still be delivered before upstream timeouts fire.
	mdnsHeadroom = 500 * time.Millisecond
	// mdnsMinWindow is the smallest collection window we accept. Without it a
	// caller deadline tighter than mdnsHeadroom would clamp the window into the
	// past, which sends the query and then gives up before any responder can
	// possibly answer.
	mdnsMinWindow = 200 * time.Millisecond
	// mdnsNegativeTTL is the lifetime of a synthesized negative answer. It
	// matches the TTL responders use for legacy unicast queries: long enough to
	// avoid re-flooding the link, short enough that a host appearing on the
	// network is picked up quickly.
	mdnsNegativeTTL = 10
)

var (
	mdnsGroupIPv4  = net.IPv4(224, 0, 0, 251)
	mdnsGroupIPv6  = net.ParseIP("ff02::fb")
	mdnsLocalZones = []string{
		"local.",
		"254.169.in-addr.arpa.",
		"8.e.f.ip6.arpa.",
		"9.e.f.ip6.arpa.",
		"a.e.f.ip6.arpa.",
		"b.e.f.ip6.arpa.",
	}
)

func IsLocalDomain(name string) bool {
	canonical := mDNS.CanonicalName(name)
	return common.Any(mdnsLocalZones, func(zone string) bool {
		return zoneMatches(canonical, zone)
	})
}

func zoneMatches(canonical string, zone string) bool {
	return canonical == zone || strings.HasSuffix(canonical, "."+zone)
}

// localZoneOf returns the link-local zone a name belongs to, falling back to
// the name itself when the transport is used for something outside them.
func localZoneOf(name string) string {
	canonical := mDNS.CanonicalName(name)
	for _, zone := range mdnsLocalZones {
		if zoneMatches(canonical, zone) {
			return zone
		}
	}
	return canonical
}

func RegisterTransport(registry *dns.TransportRegistry) {
	dns.RegisterTransport[option.MDNSDNSServerOptions](registry, C.DNSTypeMDNS, NewTransport)
}

var (
	_ adapter.DNSTransport                    = (*Transport)(nil)
	_ adapter.DNSTransportWithPreferredDomain = (*Transport)(nil)
	_ adapter.DNSTransportWithEnvironment     = (*Transport)(nil)
)

type Transport struct {
	dns.TransportAdapter
	ctx            context.Context
	logger         logger.ContextLogger
	networkManager adapter.NetworkManager
	interfaceNames badoption.Listable[string]
	configSource   *systemconfig.Source
}

func NewTransport(ctx context.Context, logger log.ContextLogger, tag string, options option.MDNSDNSServerOptions) (adapter.DNSTransport, error) {
	return &Transport{
		TransportAdapter: dns.NewTransportAdapterWithLocalOptions(C.DNSTypeMDNS, tag, options.LocalDNSServerOptions),
		ctx:              ctx,
		logger:           logger,
		networkManager:   service.FromContext[adapter.NetworkManager](ctx),
		interfaceNames:   options.Interface,
		configSource:     systemconfig.NewSource(ctx),
	}, nil
}

func NewRawTransport(transportAdapter dns.TransportAdapter, ctx context.Context, logger log.ContextLogger) *Transport {
	return &Transport{
		TransportAdapter: transportAdapter,
		ctx:              ctx,
		logger:           logger,
		networkManager:   service.FromContext[adapter.NetworkManager](ctx),
	}
}

func (t *Transport) Start(stage adapter.StartStage, scope *adapter.Scope) error {
	if stage == adapter.StartStateInitialize && t.configSource != nil {
		scope.Add(t.configSource.Close)
	}
	return nil
}

func (t *Transport) Reset() {
	if t.configSource != nil {
		t.configSource.Reset()
	}
}

func (t *Transport) PreferredDomain(domain string) bool {
	return IsLocalDomain(domain)
}

func (t *Transport) Environment() []string {
	if t.configSource == nil {
		return nil
	}
	return t.configSource.Configuration().Signature()
}

func (t *Transport) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	targets, err := t.queryTargets()
	if err != nil {
		return nil, E.Cause(err, "mdns: prepare interfaces")
	}
	request := makeQueryMessage(message)
	rawMessage, err := request.Pack()
	if err != nil {
		return nil, E.Cause(err, "mdns: pack request")
	}
	question := message.Question[0]
	exchangeCtx, cancel := context.WithDeadline(ctx, queryDeadline(ctx, time.Now()))
	defer cancel()
	results := make(chan exchangeResult, len(targets))
	for _, target := range targets {
		go func() {
			sent, err := t.exchangeTarget(exchangeCtx, target, rawMessage, question, func(candidate *mDNS.Msg) {
				results <- exchangeResult{response: candidate}
			})
			results <- exchangeResult{sent: sent, err: err}
		}()
	}

	response := newResponse(message)
	seenRecords := make(map[string]bool)
	// PTR and ANY questions expect shared records from multiple responders,
	// so they always use the full collection window.
	settleEligible := question.Qtype != mDNS.TypePTR && question.Qtype != mDNS.TypeANY
	var (
		settleTimer  *time.Timer
		targetErrors []error
		sentQuery    bool
	)
	// Drain all results, including after cancellation. Each target sends its
	// completion (a result without a response) after its last candidate.
	for remaining := len(targets); remaining > 0; {
		result := <-results
		if result.response != nil {
			mergeResponse(response, result.response, seenRecords)
			if settleEligible && settleTimer == nil && len(response.Answer) > 0 {
				settleTimer = time.AfterFunc(mdnsSettleTimeout, cancel)
				defer settleTimer.Stop()
			}
			continue
		}
		remaining--
		sentQuery = sentQuery || result.sent
		if result.err != nil {
			targetErrors = append(targetErrors, result.err)
			t.logger.TraceContext(ctx, result.err)
		}
	}
	if len(response.Answer) > 0 || len(response.Ns) > 0 || len(response.Extra) > 0 {
		return response, nil
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if sentQuery {
		// A query without a response is normal for mDNS. Return cacheable
		// NODATA rather than an error that would tear down sibling queries.
		appendNegativeAuthority(response, question)
		return response, nil
	}
	if len(targetErrors) > 0 {
		return nil, E.Errors(targetErrors...)
	}
	return nil, E.New("mdns: no query was sent")
}

func (t *Transport) ExchangeAsync(ctx context.Context, message *mDNS.Msg, callback func(response *mDNS.Msg, err error)) {
	go func() {
		callback(t.Exchange(ctx, message))
	}()
}

// queryDeadline reserves mdnsHeadroom before the caller's deadline when
// possible, clamping the collection window to [mdnsMinWindow, mdnsTimeout].
// The minimum avoids an instant empty answer when the caller gives us less
// than mdnsHeadroom. The caller's context can still end the window sooner.
func queryDeadline(ctx context.Context, now time.Time) time.Time {
	deadline := now.Add(mdnsTimeout)
	if ctxDeadline, loaded := ctx.Deadline(); loaded && !ctxDeadline.IsZero() {
		if clamped := ctxDeadline.Add(-mdnsHeadroom); clamped.Before(deadline) {
			deadline = clamped
		}
	}
	if minDeadline := now.Add(mdnsMinWindow); deadline.Before(minDeadline) {
		deadline = minDeadline
	}
	return deadline
}

type queryTarget struct {
	iface  control.Interface
	family string
}

type exchangeResult struct {
	response *mDNS.Msg
	sent     bool
	err      error
}

func (t *Transport) exchangeTarget(ctx context.Context, target queryTarget, rawMessage []byte, question mDNS.Question, onResponse func(*mDNS.Msg)) (bool, error) {
	packetConn, destination, err := t.listenPacket(ctx, target)
	if err != nil {
		return false, err
	}
	defer packetConn.Close()
	// The window, settle timer and caller cancellation all wake the same read.
	stopRead := context.AfterFunc(ctx, func() {
		packetConn.SetReadDeadline(time.Now())
	})
	defer stopRead()

	_, err = packetConn.WriteTo(rawMessage, destination)
	if err != nil {
		return false, E.Cause(err, "mdns: write request on ", target.iface.Name, " ", target.family)
	}
	buffer := buf.Get(buf.UDPBufferSize)
	defer buf.Put(buffer)
	for ctx.Err() == nil {
		n, source, readErr := packetConn.ReadFrom(buffer)
		if readErr != nil {
			if ctx.Err() != nil || E.IsTimeout(readErr) {
				break
			}
			return true, E.Cause(readErr, "mdns: read response on ", target.iface.Name, " ", target.family)
		}
		if !validSource(source, target) {
			continue
		}
		var candidate mDNS.Msg
		err = candidate.Unpack(buffer[:n])
		if err != nil {
			t.logger.TraceContext(ctx, "mdns: unpack response: ", err)
			continue
		}
		if !validResponse(&candidate, question) {
			continue
		}
		normalizeResponse(&candidate, question)
		onResponse(&candidate)
	}
	return true, nil
}

func (t *Transport) listenPacket(ctx context.Context, target queryTarget) (net.PacketConn, net.Addr, error) {
	var listenConfig net.ListenConfig
	listenConfig.Control = control.Append(listenConfig.Control, control.BindToInterface(t.networkManager.InterfaceFinder(), target.iface.Name, target.iface.Index))
	netInterface := target.iface.NetInterface()
	switch target.family {
	case "udp4":
		packetConn, err := listenConfig.ListenPacket(ctx, "udp4", "0.0.0.0:0")
		if err != nil {
			return nil, nil, E.Cause(err, "mdns: listen on ", target.iface.Name, " udp4")
		}
		ipv4Conn := ipv4.NewPacketConn(packetConn)
		err = ipv4Conn.SetMulticastInterface(&netInterface)
		if err != nil {
			packetConn.Close()
			return nil, nil, E.Cause(err, "mdns: set multicast interface on ", target.iface.Name, " udp4")
		}
		_ = ipv4Conn.SetMulticastTTL(255)
		return packetConn, &net.UDPAddr{IP: mdnsGroupIPv4, Port: mdnsPort}, nil
	case "udp6":
		packetConn, err := listenConfig.ListenPacket(ctx, "udp6", "[::]:0")
		if err != nil {
			return nil, nil, E.Cause(err, "mdns: listen on ", target.iface.Name, " udp6")
		}
		ipv6Conn := ipv6.NewPacketConn(packetConn)
		err = ipv6Conn.SetMulticastInterface(&netInterface)
		if err != nil {
			packetConn.Close()
			return nil, nil, E.Cause(err, "mdns: set multicast interface on ", target.iface.Name, " udp6")
		}
		_ = ipv6Conn.SetMulticastHopLimit(255)
		return packetConn, &net.UDPAddr{IP: mdnsGroupIPv6, Port: mdnsPort, Zone: target.iface.Name}, nil
	default:
		return nil, nil, E.New("mdns: unknown network: ", target.family)
	}
}

func (t *Transport) queryTargets() ([]queryTarget, error) {
	interfaces, err := t.fetchInterfaces()
	if err != nil {
		return nil, err
	}
	var targets []queryTarget
	for _, iface := range interfaces {
		supports4, supports6 := interfaceFamilies(iface)
		if supports4 {
			targets = append(targets, queryTarget{
				iface:  iface,
				family: "udp4",
			})
		}
		if supports6 {
			targets = append(targets, queryTarget{
				iface:  iface,
				family: "udp6",
			})
		}
	}
	if len(targets) == 0 {
		return nil, E.New("missing usable mDNS interfaces")
	}
	return targets, nil
}

func (t *Transport) fetchInterfaces() ([]control.Interface, error) {
	finder := t.networkManager.InterfaceFinder()
	var interfaces []control.Interface
	if len(t.interfaceNames) > 0 {
		for _, interfaceName := range t.interfaceNames {
			iface, err := finder.ByName(interfaceName)
			if err != nil {
				t.logger.Warn("mdns: interface ", interfaceName, " not found")
				continue
			}
			// An explicitly configured interface is taken at its word, including
			// point-to-point links: the operator knows their topology better
			// than auto-discovery does.
			if !isUsableInterface(*iface) {
				t.logger.Warn("mdns: interface ", interfaceName, " is not usable")
				continue
			}
			interfaces = append(interfaces, *iface)
		}
	} else {
		var myInterfaces []string
		interfaceMonitor := t.networkManager.InterfaceMonitor()
		if interfaceMonitor != nil {
			myInterfaces = interfaceMonitor.MyInterfaces()
		}
		interfaces = common.Filter(finder.Interfaces(), func(iface control.Interface) bool {
			return isAutoUsableInterface(iface) && !slices.Contains(myInterfaces, iface.Name)
		})
	}
	if len(interfaces) == 0 {
		return nil, E.New("mdns: missing usable interface")
	}
	return interfaces, nil
}

// isUsableInterface reports whether mDNS can run on iface at all.
func isUsableInterface(iface control.Interface) bool {
	return iface.Flags&net.FlagUp != 0 &&
		iface.Flags&net.FlagMulticast != 0 &&
		iface.Flags&net.FlagLoopback == 0
}

// isAutoUsableInterface additionally skips point-to-point links when picking
// interfaces automatically: mDNS is link-local, tunnels (VPNs) cannot carry it,
// and multicast writes on them fail on some platforms. Interfaces named in the
// configuration bypass this and only go through isUsableInterface.
func isAutoUsableInterface(iface control.Interface) bool {
	return isUsableInterface(iface) && iface.Flags&net.FlagPointToPoint == 0
}

func interfaceFamilies(iface control.Interface) (supports4, supports6 bool) {
	for _, prefix := range iface.Addresses {
		addr := prefix.Addr()
		if addr.IsLoopback() {
			continue
		}
		if addr.Is4() {
			supports4 = true
		} else if addr.Is6() && !addr.Is4In6() {
			supports6 = true
		}
		if supports4 && supports6 {
			return
		}
	}
	return
}

func makeQueryMessage(message *mDNS.Msg) *mDNS.Msg {
	request := &mDNS.Msg{
		Question: slices.Clone(message.Question),
	}
	for i := range request.Question {
		stripQuestionClass(&request.Question[i])
	}
	return request
}

func newResponse(message *mDNS.Msg) *mDNS.Msg {
	response := newResponseFromQuestion(message.Question[0])
	response.Id = message.Id
	return response
}

func newResponseFromQuestion(question mDNS.Question) *mDNS.Msg {
	stripQuestionClass(&question)
	return &mDNS.Msg{
		MsgHdr: mDNS.MsgHdr{
			Response:      true,
			Authoritative: true,
			Rcode:         mDNS.RcodeSuccess,
		},
		Question: []mDNS.Question{question},
	}
}

// appendNegativeAuthority synthesizes the SOA record that RFC 2308 negative
// caching keys off. Nothing is authoritative for a link-local zone, so the
// record exists only to carry a TTL: without it dns.Client computes a zero
// lifetime, declines to cache the empty answer, and every repeated lookup
// floods the link again.
func appendNegativeAuthority(response *mDNS.Msg, question mDNS.Question) {
	zone := localZoneOf(question.Name)
	response.Ns = append(response.Ns, &mDNS.SOA{
		Hdr: mDNS.RR_Header{
			Name:   zone,
			Rrtype: mDNS.TypeSOA,
			Class:  mDNS.ClassINET,
			Ttl:    mdnsNegativeTTL,
		},
		Ns:      zone,
		Mbox:    zone,
		Serial:  1,
		Refresh: mdnsNegativeTTL,
		Retry:   mdnsNegativeTTL,
		Expire:  mdnsNegativeTTL,
		Minttl:  mdnsNegativeTTL,
	})
}

func validSource(source net.Addr, target queryTarget) bool {
	sourceUDP, isUDP := source.(*net.UDPAddr)
	if !isUDP || sourceUDP.Port != mdnsPort {
		return false
	}
	sourceAddr, loaded := netip.AddrFromSlice(sourceUDP.IP)
	if !loaded {
		return false
	}
	sourceAddr = sourceAddr.Unmap()
	if (target.family == "udp4" && !sourceAddr.Is4()) || (target.family == "udp6" && !sourceAddr.Is6()) {
		return false
	}
	for _, prefix := range target.iface.Addresses {
		if prefix.Contains(sourceAddr) {
			return true
		}
	}
	return false
}

func validResponse(response *mDNS.Msg, question mDNS.Question) bool {
	if !response.Response ||
		response.Opcode != mDNS.OpcodeQuery ||
		response.Rcode != mDNS.RcodeSuccess {
		return false
	}
	for _, responseQuestion := range response.Question {
		if questionMatches(responseQuestion, question) {
			return true
		}
	}
	return responseHasMatchingRecord(response, question)
}

func responseHasMatchingRecord(response *mDNS.Msg, question mDNS.Question) bool {
	for _, recordList := range [][]mDNS.RR{response.Answer, response.Ns, response.Extra} {
		for _, record := range recordList {
			if recordMatchesQuestion(record, question) {
				return true
			}
		}
	}
	return false
}

func questionMatches(left mDNS.Question, right mDNS.Question) bool {
	stripQuestionClass(&left)
	stripQuestionClass(&right)
	return left.Qtype == right.Qtype &&
		left.Qclass == right.Qclass &&
		strings.EqualFold(left.Name, right.Name)
}

func recordMatchesQuestion(record mDNS.RR, question mDNS.Question) bool {
	header := record.Header()
	return strings.EqualFold(header.Name, question.Name) &&
		(question.Qtype == mDNS.TypeANY ||
			header.Rrtype == question.Qtype ||
			header.Rrtype == mDNS.TypeCNAME)
}

func normalizeResponse(response *mDNS.Msg, question mDNS.Question) {
	response.Id = 0
	response.Question = []mDNS.Question{question}
	for i := range response.Question {
		stripQuestionClass(&response.Question[i])
	}
	for _, recordList := range [][]mDNS.RR{response.Answer, response.Ns, response.Extra} {
		for _, record := range recordList {
			stripRecordClass(record)
		}
	}
}

func mergeResponse(destination *mDNS.Msg, source *mDNS.Msg, seenRecords map[string]bool) {
	appendRecords := func(destinationRecords *[]mDNS.RR, sourceRecords []mDNS.RR) {
		for _, record := range sourceRecords {
			key := record.String()
			if seenRecords[key] {
				continue
			}
			seenRecords[key] = true
			*destinationRecords = append(*destinationRecords, record)
		}
	}
	appendRecords(&destination.Answer, source.Answer)
	appendRecords(&destination.Ns, source.Ns)
	appendRecords(&destination.Extra, source.Extra)
}

func stripQuestionClass(question *mDNS.Question) {
	question.Qclass &^= mdnsClassTopBit
}

func stripRecordClass(record mDNS.RR) {
	record.Header().Class &^= mdnsClassTopBit
}
