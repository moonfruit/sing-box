package daemon

import (
	"sync/atomic"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	M "github.com/sagernet/sing/common/metadata"

	"github.com/stretchr/testify/require"
)

func TestBuildConnectionProtoUsesSniffHost(t *testing.T) {
	metadata := &trafficcontrol.TrackerMetadata{
		Metadata: adapter.InboundContext{
			SniffHost: "sniff.example.com",
		},
		Upload:   new(atomic.Int64),
		Download: new(atomic.Int64),
	}

	connection := buildConnectionProto(metadata)
	require.Equal(t, "sniff.example.com", connection.Domain)
	require.Equal(t, "sniff.example.com", connection.SniffHost)
}

func TestBuildConnectionProtoKeepsSniffHostSeparateFromDomain(t *testing.T) {
	metadata := &trafficcontrol.TrackerMetadata{
		Metadata: adapter.InboundContext{
			Destination: M.ParseSocksaddr("destination.example.com:443"),
			SniffHost:   "sniff.example.com",
		},
		Upload:   new(atomic.Int64),
		Download: new(atomic.Int64),
	}

	connection := buildConnectionProto(metadata)
	require.Equal(t, "destination.example.com", connection.Domain)
	require.Equal(t, "sniff.example.com", connection.SniffHost)
}
