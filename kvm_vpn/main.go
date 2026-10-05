package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	socketPath        = "/var/run/kvm_vpn.sock"
	displaySyncPeriod = 5 * time.Second
	defaultCmdTimeout = 5 * time.Second
)

// WorkerPool manages execution of VPN background tasks and action processing
// without allocating new goroutines dynamically, controlling GC and RSS on embedded Linux.
type WorkerPool struct {
	tasks    chan func()
	workers  int
	idleTick *time.Timer
	idleMu   sync.Mutex
	busy     int32
}

func newWorkerPool(numWorkers, queueSize int) *WorkerPool {
	p := &WorkerPool{
		tasks:   make(chan func(), queueSize),
		workers: numWorkers,
	}
	for i := 0; i < numWorkers; i++ {
		go p.workerLoop()
	}
	return p
}

func (p *WorkerPool) Submit(task func()) bool {
	select {
	case p.tasks <- task:
		return true
	default:
		log.Println("[kvm_vpn] Worker pool task queue full, dropping task")
		return false
	}
}

func (p *WorkerPool) workerLoop() {
	for task := range p.tasks {
		atomic.AddInt32(&p.busy, 1)
		task()
		atomic.AddInt32(&p.busy, -1)
		p.scheduleControlledGC()
	}
}

func (p *WorkerPool) scheduleControlledGC() {
	p.idleMu.Lock()
	defer p.idleMu.Unlock()
	// Trigger GC only when queue is drained and no workers are active
	if len(p.tasks) == 0 && atomic.LoadInt32(&p.busy) == 0 {
		if p.idleTick != nil {
			p.idleTick.Stop()
		}
		p.idleTick = time.AfterFunc(2*time.Second, func() {
			p.idleMu.Lock()
			defer p.idleMu.Unlock()
			if len(p.tasks) == 0 && atomic.LoadInt32(&p.busy) == 0 {
				runtime.GC()
				debug.FreeOSMemory()
			}
		})
	}
}

var vpnWorkerPool = newWorkerPool(2, 32)

// CtrlAction represents incoming request from kvm_app.
type CtrlAction struct {
	Action string                 `json:"action"`
	Seq    int32                  `json:"seq,omitempty"`
	Params map[string]interface{} `json:"params,omitempty"`
}

// CtrlResponse represents outgoing response or event to kvm_app.
type CtrlResponse struct {
	Seq    int32                  `json:"seq,omitempty"`
	Error  string                 `json:"error,omitempty"`
	Errno  int32                  `json:"errno,omitempty"`
	Result map[string]interface{} `json:"result,omitempty"`
	Event  string                 `json:"event,omitempty"`
	Data   json.RawMessage        `json:"data,omitempty"`
}

// VpnUpdateDisplayState is sent to kvm_app to update the front LCD status icons.
type VpnUpdateDisplayState struct {
	TailScaleState string `json:"TailScaleState"`
	ZeroTierState  string `json:"ZeroTierState"`
}

type VPNManager struct {
	mu sync.RWMutex

	// Tailscale state
	tsState       string
	tsIP          string
	tsLoginURL    string
	tsXEdge       bool
	tsLastRefresh time.Time
	tsRefreshing  bool

	// ZeroTier state
	ztState       string
	ztNetworkID   string
	ztIP          string
	ztLastRefresh time.Time
	ztRefreshing  bool
}

var vpnMgr = &VPNManager{
	tsState: "disconnected",
	ztState: "disconnected",
}

// candidatePaths searches common binary installation locations on embedded Linux.
func findBinary(names ...string) string {
	for _, name := range names {
		if path, err := exec.LookPath(name); err == nil {
			return path
		}
		standardLocations := []string{
			filepath.Join("/usr/bin", name),
			filepath.Join("/usr/sbin", name),
			filepath.Join("/userdata/vpn-tools", name),
			filepath.Join("/userdata/vpn-tools", name, "current", name),
			filepath.Join("/userdata/picokvm/bin", name),
		}
		for _, loc := range standardLocations {
			if info, err := os.Stat(loc); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
				return loc
			}
		}
	}
	return ""
}

// --- Tailscale Management ---

type tailscaleStatusJSON struct {
	BackendState string   `json:"BackendState"`
	AuthURL      string   `json:"AuthURL"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Self         struct {
		Online       bool     `json:"Online"`
		TailscaleIPs []string `json:"TailscaleIPs"`
	} `json:"Self"`
}

func findTailscaleSocket() string {
	candidates := []string{
		"/run/tailscale/tailscaled.sock",
		"/var/run/tailscale/tailscaled.sock",
	}
	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && (fi.Mode()&os.ModeSocket != 0 || !fi.IsDir()) {
			return p
		}
	}
	return ""
}

func isTailscaleDaemonAlive(sockPath string) bool {
	if sockPath == "" {
		return false
	}
	conn, err := net.DialTimeout("unix", sockPath, 80*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func (m *VPNManager) queryTailscaleStatus() {
	sockPath := findTailscaleSocket()
	if sockPath == "" || !isTailscaleDaemonAlive(sockPath) {
		m.mu.Lock()
		if m.tsState != "connecting" {
			m.tsState = "disconnected"
		}
		m.tsIP = ""
		m.tsLoginURL = ""
		m.tsLastRefresh = time.Now()
		m.mu.Unlock()
		return
	}

	var status tailscaleStatusJSON
	parsed := false

	// Method 1: LocalAPI HTTP endpoint directly over unix socket (takes ~1ms, 0 subprocess forks)
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sockPath)
			},
		},
		Timeout: 1200 * time.Millisecond,
	}
	req, err := http.NewRequest("GET", "http://local-tailscaled.sock/localapi/v0/status", nil)
	if err == nil {
		resp, err := client.Do(req)
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				if err := json.NewDecoder(resp.Body).Decode(&status); err == nil {
					parsed = true
				}
			}
		}
	}

	// Method 2: Fallback to CLI with --socket and --peers=false
	if !parsed {
		tsBin := findBinary("tailscale")
		if tsBin != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, tsBin, "--socket="+sockPath, "status", "--json", "--peers=false")
			out, err := cmd.Output()
			if err == nil {
				if err := json.Unmarshal(out, &status); err == nil {
					parsed = true
				}
			}
		}
	}

	if !parsed {
		m.mu.Lock()
		if m.tsState != "connecting" {
			m.tsState = "disconnected"
		}
		m.tsLastRefresh = time.Now()
		m.mu.Unlock()
		return
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.tsLastRefresh = time.Now()

	switch status.BackendState {
	case "Running":
		m.tsState = "logined"
		m.tsLoginURL = ""
		ips := status.TailscaleIPs
		if len(ips) == 0 {
			ips = status.Self.TailscaleIPs
		}
		if len(ips) > 0 {
			m.tsIP = ips[0]
		}
	case "NeedsLogin":
		if status.AuthURL != "" {
			m.tsLoginURL = status.AuthURL
		}
		if m.tsLoginURL != "" {
			m.tsState = "connected"
		} else {
			m.tsState = "connecting"
		}
	case "NeedsMachineAuth":
		m.tsState = "connected"
	default:
		if m.tsState != "connecting" {
			m.tsState = "disconnected"
			m.tsIP = ""
			m.tsLoginURL = ""
		}
	}
}

func (m *VPNManager) refreshTailscaleStatusAsync() {
	m.mu.Lock()
	if m.tsRefreshing || time.Since(m.tsLastRefresh) < 2*time.Second {
		m.mu.Unlock()
		return
	}
	m.tsRefreshing = true
	m.mu.Unlock()

	vpnWorkerPool.Submit(func() {
		defer func() {
			m.mu.Lock()
			m.tsRefreshing = false
			m.tsLastRefresh = time.Now()
			m.mu.Unlock()
		}()
		m.queryTailscaleStatus()
	})
}

func (m *VPNManager) loginTailscale(xEdge bool) error {
	tsBin := findBinary("tailscale")
	if tsBin == "" {
		return fmt.Errorf("tailscale binary not found on system (install to /usr/bin or /userdata/vpn-tools)")
	}

	m.mu.Lock()
	m.tsXEdge = xEdge
	m.tsState = "connecting"
	m.tsLoginURL = ""
	m.tsIP = ""
	m.mu.Unlock()

	// Ensure tailscaled is running
	ensureTailscaledRunning()

	sockPath := findTailscaleSocket()
	if sockPath == "" {
		sockPath = "/run/tailscale/tailscaled.sock"
	}

	vpnWorkerPool.Submit(func() {
		args := []string{"--socket=" + sockPath, "up", "--reset"}
		if xEdge {
			args = append(args, "--login-server", "https://login.xedge.cc")
		}

		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()

		cmd := exec.CommandContext(ctx, tsBin, args...)
		out, _ := cmd.CombinedOutput()
		outputStr := string(out)

		// Parse auth URL if output contains one
		for _, line := range strings.Split(outputStr, "\n") {
			line = strings.TrimSpace(line)
			if strings.Contains(line, "https://") && (strings.Contains(line, "login") || strings.Contains(line, "auth")) {
				m.mu.Lock()
				fields := strings.Fields(line)
				for _, f := range fields {
					if strings.HasPrefix(f, "http") {
						m.tsLoginURL = f
						m.tsState = "connected"
						break
					}
				}
				m.mu.Unlock()
				break
			}
		}

		// Refresh status
		m.queryTailscaleStatus()
	})

	return nil
}

func (m *VPNManager) logoutTailscale() error {
	tsBin := findBinary("tailscale")
	sockPath := findTailscaleSocket()
	if sockPath == "" {
		sockPath = "/run/tailscale/tailscaled.sock"
	}
	if tsBin != "" && isTailscaleDaemonAlive(sockPath) {
		ctx, cancel := context.WithTimeout(context.Background(), defaultCmdTimeout)
		defer cancel()
		_ = exec.CommandContext(ctx, tsBin, "--socket="+sockPath, "down").Run()
		_ = exec.CommandContext(ctx, tsBin, "--socket="+sockPath, "logout").Run()
	}

	m.mu.Lock()
	m.tsState = "disconnected"
	m.tsIP = ""
	m.tsLoginURL = ""
	m.tsLastRefresh = time.Now()
	m.mu.Unlock()
	return nil
}

func ensureTailscaledRunning() {
	sockPath := findTailscaleSocket()
	if isTailscaleDaemonAlive(sockPath) {
		return
	}
	if exec.Command("pgrep", "-x", "tailscaled").Run() == nil {
		return
	}
	daemonBin := findBinary("tailscaled")
	if daemonBin == "" {
		return
	}
	_ = os.MkdirAll("/run/tailscale", 0755)
	_ = os.MkdirAll("/userdata/tailscale", 0755)
	cmd := exec.Command(daemonBin,
		"--state=/userdata/tailscale/tailscaled.state",
		"--socket=/run/tailscale/tailscaled.sock",
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	logFile, err := os.OpenFile("/userdata/tailscale/tailscaled.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	_ = cmd.Start()
	time.Sleep(1 * time.Second)
}

// --- ZeroTier Management ---

func (m *VPNManager) refreshZeroTierStatusAsync(networkID string) {
	m.mu.Lock()
	if m.ztRefreshing || (time.Since(m.ztLastRefresh) < 2*time.Second && m.ztNetworkID == networkID) {
		m.mu.Unlock()
		return
	}
	m.ztRefreshing = true
	m.mu.Unlock()

	vpnWorkerPool.Submit(func() {
		defer func() {
			m.mu.Lock()
			m.ztRefreshing = false
			m.ztLastRefresh = time.Now()
			m.mu.Unlock()
		}()
		m.queryZeroTierStatus(networkID)
	})
}

func findZeroTierCli() (string, []string) {
	if bin := findBinary("zerotier-cli"); bin != "" {
		return bin, nil
	}
	if bin := findBinary("zerotier-one"); bin != "" {
		// Attempt to auto-create symlink next to binary if possible
		cliSymlink := filepath.Join(filepath.Dir(bin), "zerotier-cli")
		if _, err := os.Stat(cliSymlink); os.IsNotExist(err) {
			_ = os.Symlink(bin, cliSymlink)
		}
		if _, err := os.Stat(cliSymlink); err == nil {
			return cliSymlink, nil
		}
		return bin, []string{"-q"}
	}
	return "", nil
}

func (m *VPNManager) queryZeroTierStatus(networkID string) {
	if networkID == "" {
		m.mu.Lock()
		m.ztState = "disconnected"
		m.ztNetworkID = ""
		m.ztIP = ""
		m.ztLastRefresh = time.Now()
		m.mu.Unlock()
		return
	}

	bin, baseArgs := findZeroTierCli()
	if bin == "" {
		m.mu.Lock()
		m.ztState = "closed"
		m.ztIP = ""
		m.ztLastRefresh = time.Now()
		m.mu.Unlock()
		return
	}

	if _, err := os.Stat("/var/lib/zerotier-one/zerotier-one.pid"); os.IsNotExist(err) {
		m.mu.Lock()
		m.ztState = "closed"
		m.ztIP = ""
		m.ztLastRefresh = time.Now()
		m.mu.Unlock()
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), defaultCmdTimeout)
	defer cancel()

	args := append([]string{}, baseArgs...)
	args = append(args, "listnetworks", "-j")
	cmd := exec.CommandContext(ctx, bin, args...)
	out, err := cmd.Output()
	if err != nil {
		m.mu.Lock()
		m.ztState = "closed"
		m.ztIP = ""
		m.mu.Unlock()
		return
	}

	var networks []struct {
		ID                string   `json:"id"`
		Status            string   `json:"status"`
		AssignedAddresses []string `json:"assignedAddresses"`
	}

	if err := json.Unmarshal(out, &networks); err != nil {
		return
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	found := false
	for _, n := range networks {
		if strings.EqualFold(n.ID, networkID) {
			found = true
			m.ztNetworkID = n.ID
			switch n.Status {
			case "OK":
				m.ztState = "connected"
				if len(n.AssignedAddresses) > 0 {
					ip := n.AssignedAddresses[0]
					if slashIdx := strings.Index(ip, "/"); slashIdx != -1 {
						ip = ip[:slashIdx]
					}
					m.ztIP = ip
				}
			case "REQUESTING_CONFIGURATION":
				m.ztState = "logined"
			case "ACCESS_DENIED":
				m.ztState = "closed"
			default:
				m.ztState = "connecting"
			}
			break
		}
	}

	if !found {
		m.ztState = "closed"
		m.ztIP = ""
	}
}

func (m *VPNManager) loginZeroTier(networkID string) error {
	bin, baseArgs := findZeroTierCli()
	if bin == "" {
		return fmt.Errorf("neither zerotier-cli nor zerotier-one binary found on system")
	}

	ensureZeroTierDaemonRunning()

	ctx, cancel := context.WithTimeout(context.Background(), defaultCmdTimeout)
	defer cancel()

	m.mu.Lock()
	m.ztNetworkID = networkID
	m.ztState = "connecting"
	m.mu.Unlock()

	args := append([]string{}, baseArgs...)
	args = append(args, "join", networkID)
	cmd := exec.CommandContext(ctx, bin, args...)
	if err := cmd.Run(); err != nil {
		m.mu.Lock()
		m.ztState = "closed"
		m.mu.Unlock()
		return fmt.Errorf("failed to join zerotier network: %w", err)
	}

	m.queryZeroTierStatus(networkID)
	return nil
}

func (m *VPNManager) logoutZeroTier(networkID string) error {
	bin, baseArgs := findZeroTierCli()
	if bin != "" && networkID != "" {
		ctx, cancel := context.WithTimeout(context.Background(), defaultCmdTimeout)
		defer cancel()
		args := append([]string{}, baseArgs...)
		args = append(args, "leave", networkID)
		_ = exec.CommandContext(ctx, bin, args...).Run()
	}

	m.mu.Lock()
	m.ztState = "disconnected"
	m.ztNetworkID = ""
	m.ztIP = ""
	m.ztLastRefresh = time.Now()
	m.mu.Unlock()
	return nil
}

func ensureZeroTierDaemonRunning() {
	if exec.Command("pgrep", "-x", "zerotier-one").Run() == nil {
		return
	}
	daemonBin := findBinary("zerotier-one")
	if daemonBin == "" {
		return
	}
	_ = os.MkdirAll("/var/lib/zerotier-one", 0755)
	cmd := exec.Command(daemonBin, "-d")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	_ = cmd.Start()
	time.Sleep(1 * time.Second)
}

// --- Action Dispatcher ---

func handleAction(action CtrlAction) CtrlResponse {
	resp := CtrlResponse{
		Seq: action.Seq,
	}

	switch action.Action {
	case "get_tailscale_state":
		vpnMgr.refreshTailscaleStatusAsync()
		vpnMgr.mu.RLock()
		resp.Event = "tailscale_state"
		resp.Result = map[string]interface{}{
			"state":    vpnMgr.tsState,
			"ip":       vpnMgr.tsIP,
			"loginUrl": vpnMgr.tsLoginURL,
			"xEdge":    vpnMgr.tsXEdge,
		}
		vpnMgr.mu.RUnlock()

	case "login_tailscale":
		xEdge := false
		if val, ok := action.Params["xEdge"]; ok {
			if b, ok := val.(bool); ok {
				xEdge = b
			}
		}
		if err := vpnMgr.loginTailscale(xEdge); err != nil {
			resp.Error = err.Error()
		} else {
			resp.Result = map[string]interface{}{"status": "ok"}
		}

	case "logout_tailscale", "cancel_tailscale":
		if err := vpnMgr.logoutTailscale(); err != nil {
			resp.Error = err.Error()
		} else {
			resp.Result = map[string]interface{}{"status": "ok"}
		}

	case "get_zerotier_state":
		netID := ""
		if val, ok := action.Params["network_id"]; ok {
			if s, ok := val.(string); ok {
				netID = s
			}
		}
		vpnMgr.refreshZeroTierStatusAsync(netID)
		vpnMgr.mu.RLock()
		resp.Event = "zerotier_state"
		resp.Result = map[string]interface{}{
			"state":      vpnMgr.ztState,
			"network_id": vpnMgr.ztNetworkID,
			"ip":         vpnMgr.ztIP,
		}
		vpnMgr.mu.RUnlock()

	case "login_zerotier":
		netID := ""
		if val, ok := action.Params["network_id"]; ok {
			if s, ok := val.(string); ok {
				netID = s
			}
		}
		if netID == "" {
			resp.Error = "network_id parameter required"
		} else {
			if err := vpnMgr.loginZeroTier(netID); err != nil {
				resp.Error = err.Error()
			} else {
				vpnMgr.mu.RLock()
				resp.Event = "zerotier_state"
				resp.Result = map[string]interface{}{
					"state":      vpnMgr.ztState,
					"network_id": vpnMgr.ztNetworkID,
					"ip":         vpnMgr.ztIP,
				}
				vpnMgr.mu.RUnlock()
			}
		}

	case "logout_zerotier":
		netID := ""
		if val, ok := action.Params["network_id"]; ok {
			if s, ok := val.(string); ok {
				netID = s
			}
		}
		if err := vpnMgr.logoutZeroTier(netID); err != nil {
			resp.Error = err.Error()
		} else {
			resp.Result = map[string]interface{}{"status": "ok"}
		}

	default:
		resp.Error = fmt.Sprintf("unsupported action: %s", action.Action)
	}

	return resp
}

func main() {
	// Tune Go runtime for single-core embedded environment (RV1106 128MB RAM):
	// 16 MiB memory ceiling prevents Linux OOM killer on 128 MB RAM.
	// GOGC=50 triggers collection earlier with smaller heaps, reducing single-core pause times.
	debug.SetMemoryLimit(16 * 1024 * 1024)
	debug.SetGCPercent(50)

	log.Println("[kvm_vpn] Starting PicoKVM VPN helper daemon...")

	// Initial status scan on daemon start
	vpnMgr.queryTailscaleStatus()

	// Listen for termination signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	for {
		log.Printf("[kvm_vpn] Connecting to IPC socket: %s", socketPath)
		conn, err := net.Dial("unixpacket", socketPath)
		if err != nil {
			log.Printf("[kvm_vpn] Waiting for %s: %v (retrying in 2s)", socketPath, err)
			select {
			case <-sigCh:
				log.Println("[kvm_vpn] Terminating on signal")
				return
			case <-time.After(2 * time.Second):
				continue
			}
		}

		log.Println("[kvm_vpn] Successfully connected to kvm_app IPC socket")
		runClientSession(conn, sigCh)
	}
}

func runClientSession(conn net.Conn, sigCh <-chan os.Signal) {
	defer conn.Close()

	sendMu := sync.Mutex{}
	sendMsg := func(resp CtrlResponse) error {
		sendMu.Lock()
		defer sendMu.Unlock()
		data, err := json.Marshal(resp)
		if err != nil {
			return err
		}
		_, err = conn.Write(data)
		return err
	}

	// Display status broadcaster
	stopDisplay := make(chan struct{})
	defer close(stopDisplay)

	go func() {
		ticker := time.NewTicker(displaySyncPeriod)
		defer ticker.Stop()

		// Initial display update upon connection
		vpnMgr.mu.RLock()
		disp := VpnUpdateDisplayState{
			TailScaleState: vpnMgr.tsState,
			ZeroTierState:  vpnMgr.ztState,
		}
		vpnMgr.mu.RUnlock()
		dispBytes, _ := json.Marshal(disp)
		_ = sendMsg(CtrlResponse{
			Event: "vpn_display_update",
			Data:  dispBytes,
		})

		for {
			select {
			case <-stopDisplay:
				return
			case <-ticker.C:
				vpnMgr.refreshTailscaleStatusAsync()
				vpnMgr.mu.RLock()
				disp := VpnUpdateDisplayState{
					TailScaleState: vpnMgr.tsState,
					ZeroTierState:  vpnMgr.ztState,
				}
				vpnMgr.mu.RUnlock()

				dispBytes, err := json.Marshal(disp)
				if err == nil {
					_ = sendMsg(CtrlResponse{
						Event: "vpn_display_update",
						Data:  dispBytes,
					})
				}
			}
		}
	}()

	// Incoming message read loop
	readBuf := make([]byte, 4096)
	for {
		// Use non-blocking / read with timeout checking sigCh
		n, err := conn.Read(readBuf)
		if err != nil {
			log.Printf("[kvm_vpn] Connection error or disconnected: %v", err)
			return
		}

		var action CtrlAction
		if err := json.Unmarshal(readBuf[:n], &action); err != nil {
			log.Printf("[kvm_vpn] Failed to unmarshal message: %v", err)
			continue
		}

		log.Printf("[kvm_vpn] Received action: %s (seq: %d)", action.Action, action.Seq)
		vpnWorkerPool.Submit(func() {
			resp := handleAction(action)
			if err := sendMsg(resp); err != nil {
				log.Printf("[kvm_vpn] Failed to send response: %v", err)
			}
		})
	}
}
