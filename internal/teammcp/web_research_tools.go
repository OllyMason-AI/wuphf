package teammcp

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	webResearchDefaultSearchLimit = 10
	webResearchMaxSearchLimit     = 10
	webResearchDefaultCharLimit   = 12000
	webResearchMaxCharLimit       = 12000
	webResearchMaxBodyBytes       = 2 * 1024 * 1024
	webResearchTimeout            = 8 * time.Second
	webResearchRateLimitWindow    = time.Hour
	webResearchRateLimitMaxCalls  = 40
)

type WebSearchArgs struct {
	Query  string `json:"query" jsonschema:"Search query. Use for public web discovery only; cite result URLs in deliverables."`
	Limit  int    `json:"limit,omitempty" jsonschema:"Maximum results to return, capped at 10. Defaults to 10."`
	MySlug string `json:"my_slug,omitempty" jsonschema:"Agent slug. Only @research / research-role agents may use this tool."`
}

type WebFetchArgs struct {
	URL       string `json:"url" jsonschema:"Public http(s) URL to fetch with GET only. Private, localhost, and authenticated browsing are blocked."`
	CharLimit int    `json:"char_limit,omitempty" jsonschema:"Maximum response characters, capped at 12000. Defaults to 12000."`
	MySlug    string `json:"my_slug,omitempty" jsonschema:"Agent slug. Only @research / research-role agents may use this tool."`
}

type webResearchRateBucket struct {
	WindowStart time.Time
	Calls       int
}

var (
	webResearchRateMu               sync.Mutex
	webResearchRateBuckets          = map[string]webResearchRateBucket{}
	webResearchAllowPrivateForTests bool
)

func isResearchAgent(slug string) bool {
	slug = strings.ToLower(strings.TrimSpace(slug))
	return slug == "research" || strings.Contains(slug, "research")
}

func registerWebResearchTools(server *mcp.Server) {
	mcp.AddTool(server, readOnlyTool(
		"web_search",
		"Read-only public web search for research agents. Returns public result titles, URLs, and snippets. GET/discovery only; no CRM, email, social, login, or browser automation. Cite source URLs in deliverables and report exact errors.",
	), handleWebSearch)
	mcp.AddTool(server, readOnlyTool(
		"web_fetch",
		"Read-only public URL fetch for research agents. GET only; blocks localhost/private IPs and caps time/size. Use to verify source pages before citing them.",
	), handleWebFetch)
}

func requireResearchAgent(argsSlug string) (string, error) {
	slug := resolveSlugOptional(argsSlug)
	if slug == "" {
		return "", fmt.Errorf("missing agent slug; web research tools are only available to @research / research-role agents")
	}
	if !isResearchAgent(slug) {
		return "", fmt.Errorf("web research tools are only available to @research / research-role agents; got @%s", slug)
	}
	return slug, nil
}

func checkWebResearchRateLimit(slug string) error {
	now := time.Now().UTC()
	webResearchRateMu.Lock()
	defer webResearchRateMu.Unlock()
	bucket := webResearchRateBuckets[slug]
	if bucket.WindowStart.IsZero() || now.Sub(bucket.WindowStart) >= webResearchRateLimitWindow {
		webResearchRateBuckets[slug] = webResearchRateBucket{WindowStart: now, Calls: 1}
		return nil
	}
	if bucket.Calls >= webResearchRateLimitMaxCalls {
		return fmt.Errorf("web research rate limit exceeded for @%s: %d calls per %s", slug, webResearchRateLimitMaxCalls, webResearchRateLimitWindow)
	}
	bucket.Calls++
	webResearchRateBuckets[slug] = bucket
	return nil
}

func handleWebSearch(ctx context.Context, _ *mcp.CallToolRequest, args WebSearchArgs) (*mcp.CallToolResult, any, error) {
	slug, err := requireResearchAgent(args.MySlug)
	if err != nil {
		return toolError(err), nil, nil
	}
	if err := checkWebResearchRateLimit(slug); err != nil {
		return toolError(err), nil, nil
	}
	query := strings.TrimSpace(args.Query)
	if query == "" {
		return toolError(fmt.Errorf("query is required")), nil, nil
	}
	limit := args.Limit
	if limit <= 0 {
		limit = webResearchDefaultSearchLimit
	}
	if limit > webResearchMaxSearchLimit {
		limit = webResearchMaxSearchLimit
	}

	results, err := runPublicWebSearch(ctx, query, limit)
	if err != nil {
		return toolError(fmt.Errorf("web_search failed: %w", err)), nil, nil
	}
	return textResult(prettyObject(map[string]any{
		"tool":     "web_search",
		"query":    query,
		"limit":    limit,
		"results":  results,
		"reminder": "Use these URLs as sources. Verify important pages with web_fetch. Do not invent facts.",
	})), nil, nil
}

func handleWebFetch(ctx context.Context, _ *mcp.CallToolRequest, args WebFetchArgs) (*mcp.CallToolResult, any, error) {
	slug, err := requireResearchAgent(args.MySlug)
	if err != nil {
		return toolError(err), nil, nil
	}
	if err := checkWebResearchRateLimit(slug); err != nil {
		return toolError(err), nil, nil
	}
	charLimit := args.CharLimit
	if charLimit <= 0 {
		charLimit = webResearchDefaultCharLimit
	}
	if charLimit > webResearchMaxCharLimit {
		charLimit = webResearchMaxCharLimit
	}
	fetchURL, err := validatePublicHTTPURL(args.URL)
	if err != nil {
		return toolError(err), nil, nil
	}
	result, err := fetchPublicURL(ctx, fetchURL, charLimit)
	if err != nil {
		return toolError(fmt.Errorf("web_fetch failed: %w", err)), nil, nil
	}
	return textResult(prettyObject(result)), nil, nil
}

type webSearchResult struct {
	Title   string `json:"title"`
	URL     string `json:"url"`
	Snippet string `json:"snippet,omitempty"`
}

func runPublicWebSearch(ctx context.Context, query string, limit int) ([]webSearchResult, error) {
	endpoint := strings.TrimSpace(os.Getenv("WUPHF_WEB_SEARCH_ENDPOINT"))
	if endpoint == "" {
		endpoint = "https://duckduckgo.com/html/"
	}
	searchURL, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("invalid search endpoint: %w", err)
	}
	values := searchURL.Query()
	if strings.Contains(searchURL.Host, "duckduckgo.com") {
		values.Set("q", query)
	} else {
		values.Set("q", query)
		values.Set("limit", strconv.Itoa(limit))
	}
	searchURL.RawQuery = values.Encode()

	if err := rejectPrivateURL(searchURL); err != nil {
		return nil, err
	}
	body, _, err := getPublicURL(ctx, searchURL.String(), 512*1024)
	if err != nil {
		return nil, err
	}
	results := parseDuckDuckGoHTMLResults(string(body), limit)
	if len(results) == 0 {
		return nil, fmt.Errorf("no results parsed from search endpoint")
	}
	return results, nil
}

func fetchPublicURL(ctx context.Context, rawURL string, charLimit int) (map[string]any, error) {
	body, headers, err := getPublicURL(ctx, rawURL, webResearchMaxBodyBytes)
	if err != nil {
		return nil, err
	}
	text := string(body)
	truncated := false
	if len([]rune(text)) > charLimit {
		runes := []rune(text)
		text = string(runes[:charLimit])
		truncated = true
	}
	return map[string]any{
		"tool":         "web_fetch",
		"url":          rawURL,
		"status":       headers.StatusCode,
		"content_type": headers.ContentType,
		"bytes_read":   len(body),
		"char_limit":   charLimit,
		"truncated":    truncated,
		"content":      text,
	}, nil
}

type publicURLHeaders struct {
	StatusCode  int
	ContentType string
}

func getPublicURL(ctx context.Context, rawURL string, maxBytes int64) ([]byte, publicURLHeaders, error) {
	validated, err := validatePublicHTTPURL(rawURL)
	if err != nil {
		return nil, publicURLHeaders{}, err
	}
	reqCtx, cancel := context.WithTimeout(ctx, webResearchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, validated, nil)
	if err != nil {
		return nil, publicURLHeaders{}, err
	}
	req.Header.Set("User-Agent", "WUPHFResearchBot/1.0 (+read-only)")
	client := &http.Client{
		Timeout: webResearchTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return fmt.Errorf("too many redirects")
			}
			return rejectPrivateURL(req.URL)
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, publicURLHeaders{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, publicURLHeaders{StatusCode: resp.StatusCode, ContentType: resp.Header.Get("Content-Type")}, fmt.Errorf("GET %s returned HTTP %d", validated, resp.StatusCode)
	}
	limited := io.LimitReader(resp.Body, maxBytes+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, publicURLHeaders{}, err
	}
	if int64(len(body)) > maxBytes {
		return nil, publicURLHeaders{StatusCode: resp.StatusCode, ContentType: resp.Header.Get("Content-Type")}, fmt.Errorf("response exceeded size cap of %d bytes", maxBytes)
	}
	return body, publicURLHeaders{StatusCode: resp.StatusCode, ContentType: resp.Header.Get("Content-Type")}, nil
}

func validatePublicHTTPURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", fmt.Errorf("only http(s) URLs are allowed")
	}
	if u.User != nil {
		return "", fmt.Errorf("authenticated URLs are not allowed")
	}
	if u.Hostname() == "" {
		return "", fmt.Errorf("URL host is required")
	}
	if err := rejectPrivateURL(u); err != nil {
		return "", err
	}
	return u.String(), nil
}

func rejectPrivateURL(u *url.URL) error {
	if webResearchAllowPrivateForTests {
		return nil
	}
	host := strings.TrimSpace(u.Hostname())
	if host == "" {
		return fmt.Errorf("URL host is required")
	}
	lower := strings.ToLower(host)
	if lower == "localhost" || strings.HasSuffix(lower, ".localhost") {
		return fmt.Errorf("localhost URLs are blocked")
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return fmt.Errorf("DNS lookup failed for %s: %w", host, err)
	}
	return rejectPrivateIPs(host, ips)
}

func rejectPrivateIPs(host string, ips []net.IP) error {
	for _, ip := range ips {
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
			return fmt.Errorf("private or non-public IP blocked for %s (%s)", host, ip.String())
		}
	}
	return nil
}

func parseDuckDuckGoHTMLResults(html string, limit int) []webSearchResult {
	links := extractDDGResultLinks(html)
	results := make([]webSearchResult, 0, limit)
	seen := map[string]bool{}
	for _, link := range links {
		if len(results) >= limit {
			break
		}
		if link.URL == "" || seen[link.URL] {
			continue
		}
		seen[link.URL] = true
		results = append(results, link)
	}
	return results
}

func extractDDGResultLinks(html string) []webSearchResult {
	var out []webSearchResult
	marker := "result__a"
	idx := 0
	for {
		pos := strings.Index(html[idx:], marker)
		if pos < 0 {
			break
		}
		idx += pos
		start := strings.LastIndex(html[:idx], "<a")
		endRel := strings.Index(html[idx:], "</a>")
		if start < 0 || endRel < 0 {
			idx += len(marker)
			continue
		}
		end := idx + endRel + len("</a>")
		anchor := html[start:end]
		href := htmlAttr(anchor, "href")
		title := stripHTML(anchor)
		cleanURL := cleanDDGURL(href)
		if cleanURL != "" && title != "" {
			out = append(out, webSearchResult{Title: title, URL: cleanURL})
		}
		idx = end
	}
	return out
}

func htmlAttr(s, attr string) string {
	for _, quote := range []string{"\"", "'"} {
		needle := attr + "=" + quote
		pos := strings.Index(s, needle)
		if pos < 0 {
			continue
		}
		start := pos + len(needle)
		end := strings.Index(s[start:], quote)
		if end < 0 {
			continue
		}
		return htmlUnescape(s[start : start+end])
	}
	return ""
}

func cleanDDGURL(raw string) string {
	raw = htmlUnescape(strings.TrimSpace(raw))
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err == nil {
		if uddg := u.Query().Get("uddg"); uddg != "" {
			if decoded, err := url.QueryUnescape(uddg); err == nil {
				return decoded
			}
			return uddg
		}
		if u.IsAbs() {
			return u.String()
		}
	}
	return raw
}

func stripHTML(s string) string {
	var b strings.Builder
	inTag := false
	for _, r := range s {
		switch r {
		case '<':
			inTag = true
		case '>':
			inTag = false
		default:
			if !inTag {
				b.WriteRune(r)
			}
		}
	}
	return strings.Join(strings.Fields(htmlUnescape(b.String())), " ")
}

func htmlUnescape(s string) string {
	replacer := strings.NewReplacer(
		"&amp;", "&",
		"&lt;", "<",
		"&gt;", ">",
		"&quot;", "\"",
		"&#39;", "'",
		"&apos;", "'",
	)
	return replacer.Replace(s)
}
