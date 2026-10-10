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
	ListenAddr   string                `json:"listen_addr"`
	SecretFile   string                `json:"secret_file"`
	Repositories map[string]RepoConfig `json:"repositories"`
}

type RepoConfig struct {
	Script string   `json:"script"`
	Args   []string `json:"args"`
}

type GithubPayload struct {
	Ref        string `json:"ref"`
	Action     string `json:"action"`
	Repository struct {
		Name string `json:"name"`
	} `json:"repository"`
	Release struct {
		TagName string `json:"tag_name"`
	} `json:"release"`
}

var (
	config Config
	secret []byte
	jobMu  sync.Mutex
)

func verifySignature(payload []byte, signatureHeader string) bool {
	const prefix = "sha256="
	if !strings.HasPrefix(signatureHeader, prefix) {
		return false
	}
	signature, err := hex.DecodeString(strings.TrimPrefix(signatureHeader, prefix))
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(payload)
	return hmac.Equal(signature, mac.Sum(nil))
}

func handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	sig := r.Header.Get("X-Hub-Signature-256")
	if !verifySignature(body, sig) {
		log.Println("WARNING: Unauthorized webhook attempt - invalid HMAC signature")
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	var payload GithubPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		http.Error(w, "Invalid JSON Payload", http.StatusBadRequest)
		return
	}

	repoName := payload.Repository.Name
	repoCfg, exists := config.Repositories[repoName]
	if !exists {
		log.Printf("INFO: Ignored webhook trigger for unmapped repository: %s\n", repoName)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Ignored: repository not configured"))
		return
	}

	// 1. Mobile Release Event (Nadi-Flutter)
	if payload.Action == "published" && payload.Release.TagName != "" {
		tag := payload.Release.TagName
		log.Printf("INFO: Valid release event published for %s (tag: %s). Fetching APK...\n", repoName, tag)
		go func() {
			jobMu.Lock()
			defer jobMu.Unlock()
			cmd := exec.Command("/opt/gym/devops/scripts/fetch-apk.sh", tag)
			cmd.Dir = "/opt/gym/devops"
			cmd.Env = append(os.Environ(), "USER=deploy", "HOME=/opt/gym")
			out, err := cmd.CombinedOutput()
			if err != nil {
				log.Printf("ERROR: fetch-apk.sh failed for %s (%s): %v\nOutput:\n%s\n", repoName, tag, err, string(out))
				return
			}
			log.Printf("SUCCESS: fetch-apk.sh completed for %s (%s):\n%s\n", repoName, tag, string(out))
		}()

		w.WriteHeader(http.StatusAccepted)
		w.Write([]byte(`{"status":"Accepted","message":"APK fetch triggered successfully"}`))
		return
	}

	// 2. Standard Code Push Event (main branch for Backend & Frontend)
	if payload.Ref == "refs/heads/main" {
		log.Printf("INFO: Valid push event received for %s on main branch. Triggering deployment script...\n", repoName)
		go func() {
			jobMu.Lock()
			defer jobMu.Unlock()
			cmd := exec.Command(repoCfg.Script, repoCfg.Args...)
			cmd.Dir = "/opt/gym/devops"
			cmd.Env = append(os.Environ(), "USER=deploy", "HOME=/opt/gym")
			out, err := cmd.CombinedOutput()
			if err != nil {
				log.Printf("ERROR: Deployment script failed for %s: %v\nOutput:\n%s\n", repoName, err, string(out))
				return
			}
			log.Printf("SUCCESS: Deployment completed successfully for %s\nOutput:\n%s\n", repoName, string(out))
		}()

		w.WriteHeader(http.StatusAccepted)
		w.Write([]byte(`{"status":"Accepted","message":"Deployment triggered successfully"}`))
		return
	}

	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"Ignored","message":"Event not actionable"}`))
}

func main() {
	cfgData, err := os.ReadFile("/etc/gym/webhook.json")
	if err != nil {
		log.Fatalf("Fatal: Failed to read config file /etc/gym/webhook.json: %v", err)
	}
	if err := json.Unmarshal(cfgData, &config); err != nil {
		log.Fatalf("Fatal: Failed to parse webhook JSON config: %v", err)
	}

	secData, err := os.ReadFile(config.SecretFile)
	if err != nil {
		log.Fatalf("Fatal: Failed to read secret file %s: %v", config.SecretFile, err)
	}
	secret = []byte(strings.TrimSpace(string(secData)))

	http.HandleFunc("/hooks/deploy", handleWebhook)
	log.Printf("Starting Webhook Daemon listening on %s...\n", config.ListenAddr)
	if err := http.ListenAndServe(config.ListenAddr, nil); err != nil {
		log.Fatalf("Fatal: Webhook daemon stopped: %v", err)
	}
}
