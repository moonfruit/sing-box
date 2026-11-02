package clashapi

import (
	"net/url"
	"strconv"

	"github.com/sagernet/sing-box/adapter"
)

func dnsQueryOptions(query url.Values) (adapter.DNSQueryOptions, error) {
	var options adapter.DNSQueryOptions
	if query.Has("skip-fake-ip") {
		skip, err := strconv.ParseBool(query.Get("skip-fake-ip"))
		if err != nil {
			return options, err
		}
		options.SkipFakeIP = skip
	}
	return options, nil
}
