package dns

import (
	"context"
	"fmt"
	"net/netip"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"

	mDNS "github.com/miekg/dns"
	"github.com/stretchr/testify/require"
)

type skipFakeIPTransport struct{ *fakeDNSTransport }

func (t *skipFakeIPTransport) Type() string { return C.DNSTypeFakeIP }

func TestExchangeSkipFakeIP(t *testing.T) {
	for _, legacy := range []bool{false, true} {
		for _, async := range []bool{false, true} {
			for _, qtype := range []uint16{mDNS.TypeA, mDNS.TypeAAAA} {
				for _, mode := range []string{"ordinary", "skip", "final", "explicit"} {
					t.Run(fmt.Sprintf("legacy=%v/async=%v/type=%d/%s", legacy, async, qtype, mode), func(t *testing.T) {
						address := "1.1.1.1"
						fakeAddress := "198.18.0.1"
						if qtype == mDNS.TypeAAAA {
							address = "2606:4700:4700::1111"
							fakeAddress = "fc00::1"
						}
						real := &fakeDNSTransport{tag: "real", address: netip.MustParseAddr(address)}
						fake := &skipFakeIPTransport{&fakeDNSTransport{tag: "fakeip", address: netip.MustParseAddr(fakeAddress)}}
						router := raceTestRouter(t, real)
						router.legacyDNSMode = legacy
						router.transport = &fakeDNSTransportManager{transports: map[string]adapter.DNSTransport{"fakeip": fake, "real": real}, defaultTransport: real}
						router.rules = raceTestRules(t, []option.DNSRule{routeRule("fakeip", false), routeRule("real", false)})
						opts := adapter.DNSQueryOptions{SkipFakeIP: mode != "ordinary"}
						if mode == "final" {
							router.rules = nil
							router.transport.(*fakeDNSTransportManager).defaultTransport = fake
						}
						if mode == "explicit" {
							opts.Transport = fake
						}
						request := new(mDNS.Msg)
						request.SetQuestion("example.com.", qtype)
						var response *mDNS.Msg
						var err error
						if async {
							done := make(chan struct{})
							router.ExchangeAsync(context.Background(), request, opts, func(msg *mDNS.Msg, e error) { response = msg; err = e; close(done) })
							<-done
						} else {
							response, err = router.Exchange(context.Background(), request, opts)
						}
						if mode == "final" || mode == "explicit" {
							require.ErrorContains(t, err, "fakeip")
							require.Zero(t, fake.queryCount.Load())
							require.Zero(t, real.queryCount.Load())
						} else {
							require.NoError(t, err)
							require.NotEmpty(t, response.Answer)
							if mode == "ordinary" {
								require.Positive(t, fake.queryCount.Load())
								require.Zero(t, real.queryCount.Load())
							} else {
								require.Zero(t, fake.queryCount.Load())
								require.Positive(t, real.queryCount.Load())
							}
						}
					})
				}
			}
		}
	}
}
