package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
)

type Config struct {
	ListenAddr   string                  `json:"listen_addr"`
	SecretFile   string                  `json:"secret_file"`
	Repositories map[string]RepoConfig   `json:"repositories"`
}

type RepoConfig struct {
	Script string   `json:"script"`
	Args   []string `json:"args"`
}

type GithubPayload struct {
	Ref        string `json:"ref"`
	Repository struct {
		Name string `json:"name"`
	} `json:"repository"`
}

var (
	config Config
	secret []byte
	jobMu  sync.Mutex
)

func verifySignature(payload []byte, signatureHeader string) bool {
	if !strings.HasPrefix(signatureHeader, "sha256=") {
		return false
	}
	signature, err := hex.DecodeString(strings.TrimPrefix(signatureHeader, "sha256="))
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(payload)
	expectedMAC := mac.Sum(nil)
	return hmac.Equal(signature, expectedMAC)
}

func handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "BadRequest", http.StatusBadRequest)
		return
	}

	sig := r.Header.Get("X-Hub-Signature-256")
	if !verifySignature(body, sig) {
		log.Println("Unauthorized webhook attempt: invalid signature")
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var payload GithubPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	repoName := payload.Repository.Name
	repoCfg, exists := config.Repositories[repoName]
	if !exists {
		log.Printf("Ignored webhook for unmapped repository: %s\n", repoName)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Ignored: repo not configured"))
		return
	}

	go func() {
		jobMu.Lock()
		defer jobMu.Unlock()

		log.Printf("Executing trigger for repo: %s via script %s\n", repoName, repoCfg.Script)
		cmd := exec.Command(repoCfg.Script, repoCfg.Args...)
		cmd.Dir = "/opt/gym/devops"
		out, err := cmd.CombinedOutput()
		if err != nil {
			log.Printf("Execution failed for %s: %v\nOutput:\n%s\n", repoName, err, string(out))
		} else {
			log.Printf("Execution succeeded for %s\nOutput:\n%s\n", repoName, string(out))
		}
	}()

	w.WriteHeader(http.StatusAccepted)
	w.Write([]byte("Deployment trigger accepted"))
}

func main() {
	cfgData, err := os.ReadFile("/etc/gym/webhook.json")
	if err != nil {
		log.Fatalf("Failed to read config file: %v", err)
	}
	if err := json.Unmarshal(cfgData, &config); err != nil {
		log.Fatalf("Failed to parse json config: %v", err)
	}

	secData, err := os.ReadFile(config.SecretFile)
	if err != nil {
		log.Fatalf("Failed to read secret file: %v", err)
	}
	secret = []byte(strings.TrimSpace(string(secData)))

	http.HandleFunc("/hooks/deploy", handleWebhook)
	log.Printf("Starting Webhook Daemon listening on %s...\n", config.ListenAddr)
	if err := http.ListenAndServe(config.ListenAddr, nil); err != nil {
		log.Fatalf("Server stopped: %v", err)
	}
}
