package route

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// dnsmasq compiled with HAVE_BROKEN_RTC (the default on routers without a
// battery-backed clock) stores the remaining lease seconds in the first field
// instead of an absolute expiry timestamp.
const brokenRTCLeases = `86400 84:46:93:c6:6e:75 192.168.50.234 yeelink-ven_fan-vf3_mibt6E75 01:84:46:93:c6:6e:75
51125 00:e0:4c:67:01:46 192.168.50.80 MoonsMacBookM2 01:00:e0:4c:67:01:46
86215 c8:91:43:46:a4:2e 192.168.50.84 * *
78912 52:54:00:c7:22:46 192.168.50.15 homeassistant 01:52:54:00:c7:22:46
58675 ee:ed:ab:b1:f0:b0 192.168.50.13 debian ff:3b:5c:5b:63:00:02:00:00:ab:11:61:4f:19:1d:96:80:34:62
duid 00:03:00:01:3a:29:37:d0:19:8d
`

func writeLeaseFile(t *testing.T, name string, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(path, []byte(content), 0o644))
	return path
}

func TestParseDnsmasqLeasesBrokenRTC(t *testing.T) {
	t.Parallel()
	path := writeLeaseFile(t, "dnsmasq.leases", brokenRTCLeases)
	ipToMAC, ipToHostname, macToHostname := ReloadLeaseFiles([]string{path})
	require.Equal(t, "homeassistant", ipToHostname[netip.MustParseAddr("192.168.50.15")])
	require.Equal(t, "MoonsMacBookM2", ipToHostname[netip.MustParseAddr("192.168.50.80")])
	require.Equal(t, "debian", ipToHostname[netip.MustParseAddr("192.168.50.13")])
	require.Equal(t, "homeassistant", macToHostname["52:54:00:c7:22:46"])
	require.Contains(t, ipToMAC, netip.MustParseAddr("192.168.50.84"))
	// The "*" placeholder is not a hostname.
	require.NotContains(t, ipToHostname, netip.MustParseAddr("192.168.50.84"))
}

func TestParseDnsmasqLeasesAbsoluteExpiry(t *testing.T) {
	t.Parallel()
	path := writeLeaseFile(t, "dnsmasq.leases",
		"1893456000 52:54:00:c7:22:46 192.168.50.15 homeassistant 01:52:54:00:c7:22:46\n"+
			"1234567890 52:54:00:c7:22:47 192.168.50.16 expired 01:52:54:00:c7:22:47\n")
	_, ipToHostname, _ := ReloadLeaseFiles([]string{path})
	require.Equal(t, "homeassistant", ipToHostname[netip.MustParseAddr("192.168.50.15")])
	require.NotContains(t, ipToHostname, netip.MustParseAddr("192.168.50.16"))
}

func TestParseDnsmasqLeasesBrokenRTCExpired(t *testing.T) {
	t.Parallel()
	path := writeLeaseFile(t, "dnsmasq.leases",
		"600 52:54:00:c7:22:46 192.168.50.15 homeassistant 01:52:54:00:c7:22:46\n")
	// Pretend the file was last written an hour ago: the 600s lease is stale.
	modTime := time.Now().Add(-time.Hour)
	require.NoError(t, os.Chtimes(path, modTime, modTime))
	_, ipToHostname, _ := ReloadLeaseFiles([]string{path})
	require.NotContains(t, ipToHostname, netip.MustParseAddr("192.168.50.15"))
}
