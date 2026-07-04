package teammcp

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestWebResearchToolsOnlyRegisteredForResearchAgents(t *testing.T) {
	researchTools := registeredToolNamesForSlug(t, "research")
	if !containsTool(researchTools, "web_search") || !containsTool(researchTools, "web_fetch") {
		t.Fatalf("expected research tools for @research, got %v", researchTools)
	}

	sdrTools := registeredToolNamesForSlug(t, "sdr")
	if containsTool(sdrTools, "web_search") || containsTool(sdrTools, "web_fetch") {
		t.Fatalf("did not expect web research tools for @sdr, got %v", sdrTools)
	}
}

func TestValidatePublicHTTPURLBlocksPrivateTargets(t *testing.T) {
	blocked := []string{
		"http://localhost:7890/health",
		"file:///etc/passwd",
		"https://user:pass@example.com/",
	}
	for _, raw := range blocked {
		if _, err := validatePublicHTTPURL(raw); err == nil {
			t.Fatalf("expected %s to be blocked", raw)
		}
	}
	privateIPs := []net.IP{
		net.ParseIP("127.0.0.1"),
		net.ParseIP("10.0.0.1"),
		net.ParseIP("192.168.1.10"),
	}
	if err := rejectPrivateIPs("internal.test", privateIPs); err == nil {
		t.Fatal("expected private IPs to be blocked")
	}
}

func TestWebFetchGETOnlyAndCapsResponse(t *testing.T) {
	webResearchAllowPrivateForTests = true
	t.Cleanup(func() { webResearchAllowPrivateForTests = false })
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != http.MethodGet {
			t.Fatalf("expected GET, got %s", r.Method)
		}
		_, _ = w.Write([]byte("abcdefghijklmnopqrstuvwxyz"))
	}))
	defer srv.Close()

	res, _, err := handleWebFetch(context.Background(), nil, WebFetchArgs{URL: srv.URL, CharLimit: 5, MySlug: "research"})
	if err != nil {
		t.Fatalf("handleWebFetch: %v", err)
	}
	if isToolError(res) {
		t.Fatalf("unexpected tool error: %s", toolErrorText(res))
	}
	text := textFromResult(t, res)
	if !strings.Contains(text, `"content": "abcde"`) || !strings.Contains(text, `"truncated": true`) {
		t.Fatalf("expected truncated fetch content, got %s", text)
	}
	if calls != 1 {
		t.Fatalf("expected one GET call, got %d", calls)
	}
}

func TestWebSearchParsesDuckDuckGoResults(t *testing.T) {
	webResearchAllowPrivateForTests = true
	t.Cleanup(func() { webResearchAllowPrivateForTests = false })
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("q"); got != "bristol recruitment" {
			t.Fatalf("expected query to be forwarded, got %q", got)
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<html><body>
<a rel="nofollow" class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Agency A</a>
<a rel="nofollow" class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fb">Agency B</a>
</body></html>`))
	}))
	defer srv.Close()
	t.Setenv("WUPHF_WEB_SEARCH_ENDPOINT", srv.URL+"/html/")

	res, _, err := handleWebSearch(context.Background(), nil, WebSearchArgs{Query: "bristol recruitment", Limit: 10, MySlug: "research"})
	if err != nil {
		t.Fatalf("handleWebSearch: %v", err)
	}
	if isToolError(res) {
		t.Fatalf("unexpected tool error: %s", toolErrorText(res))
	}
	text := textFromResult(t, res)
	if !strings.Contains(text, "Agency A") || !strings.Contains(text, "https://example.com/a") || !strings.Contains(text, "Agency B") {
		t.Fatalf("expected parsed search results, got %s", text)
	}
}

func registeredToolNamesForSlug(t *testing.T, slug string) []string {
	t.Helper()
	ctx := context.Background()
	clientTransport, serverTransport := mcp.NewInMemoryTransports()
	server := mcp.NewServer(&mcp.Implementation{Name: "wuphf-team-test", Version: "0.1.0"}, nil)
	configureServerTools(server, slug, "general", false)
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer serverSession.Wait()
	client := mcp.NewClient(&mcp.Implementation{Name: "client", Version: "0.1.0"}, nil)
	clientSession, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer clientSession.Close()
	tools, err := clientSession.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	names := make([]string, 0, len(tools.Tools))
	for _, tool := range tools.Tools {
		names = append(names, tool.Name)
	}
	return names
}

func containsTool(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}

func TestParseDuckDuckGoHTMLResultsDecodesRedirectURLs(t *testing.T) {
	html := `<a class="result__a" href="/l/?uddg=` + url.QueryEscape("https://example.org/page?x=1&y=2") + `">Example &amp; Result</a>`
	results := parseDuckDuckGoHTMLResults(html, 10)
	if len(results) != 1 {
		t.Fatalf("expected one result, got %v", results)
	}
	if results[0].Title != "Example & Result" || results[0].URL != "https://example.org/page?x=1&y=2" {
		raw, _ := json.Marshal(results)
		t.Fatalf("unexpected parsed result: %s", raw)
	}
}
