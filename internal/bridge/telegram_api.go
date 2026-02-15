package bridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type telegramUpdateResponse struct {
	OK     bool             `json:"ok"`
	Result []telegramUpdate `json:"result"`
}

type telegramGetFileResponse struct {
	OK     bool             `json:"ok"`
	Result telegramFileInfo `json:"result"`
}

type telegramFileInfo struct {
	FileID   string `json:"file_id"`
	FilePath string `json:"file_path"`
}

func getUpdates(cfg bridgeConfig, offset int64) ([]telegramUpdate, error) {
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/getUpdates", cfg.BotToken)

	params := url.Values{}
	params.Set("timeout", "50")
	params.Set("offset", strconv.FormatInt(offset, 10))

	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
	}

	var payload telegramUpdateResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("bad response: %w", err)
	}
	if !payload.OK {
		return nil, fmt.Errorf("telegram returned ok=false: %s", string(body))
	}

	return payload.Result, nil
}

func sendMessage(cfg bridgeConfig, chatID int64, text string) error {
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", cfg.BotToken)

	payload := map[string]any{
		"chat_id": chatID,
		"text":    text,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody))
	}

	return nil
}

func sendDocument(cfg bridgeConfig, chatID int64, filePath string, caption string) error {
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/sendDocument", cfg.BotToken)

	f, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer f.Close()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("chat_id", strconv.FormatInt(chatID, 10)); err != nil {
		return err
	}
	if caption != "" {
		if err := writer.WriteField("caption", caption); err != nil {
			return err
		}
	}
	part, err := writer.CreateFormFile("document", filepath.Base(filePath))
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, f); err != nil {
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, endpoint, &body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

func sendPhoto(cfg bridgeConfig, chatID int64, filePath string, caption string) error {
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/sendPhoto", cfg.BotToken)

	f, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer f.Close()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("chat_id", strconv.FormatInt(chatID, 10)); err != nil {
		return err
	}
	if caption != "" {
		if err := writer.WriteField("caption", caption); err != nil {
			return err
		}
	}
	part, err := writer.CreateFormFile("photo", filepath.Base(filePath))
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, f); err != nil {
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, endpoint, &body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

func getTelegramFilePath(cfg bridgeConfig, fileID string) (string, error) {
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/getFile", cfg.BotToken)
	params := url.Values{}
	params.Set("file_id", fileID)
	req, err := http.NewRequest(http.MethodGet, endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return "", err
	}

	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %d: %s", resp.StatusCode, string(body))
	}

	var payload telegramGetFileResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}
	if !payload.OK || strings.TrimSpace(payload.Result.FilePath) == "" {
		return "", fmt.Errorf("telegram getFile failed: %s", string(body))
	}
	return payload.Result.FilePath, nil
}

func downloadTelegramFile(cfg bridgeConfig, fileID string, originalName string) (string, error) {
	inboxDir := filepath.Join(cfg.TmpDir, "inbox")
	return downloadTelegramFileToDir(cfg, fileID, originalName, inboxDir)
}

func downloadTelegramFileToDir(cfg bridgeConfig, fileID string, originalName string, targetDir string) (string, error) {
	filePath, err := getTelegramFilePath(cfg, fileID)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(targetDir) == "" {
		return "", fmt.Errorf("target dir is empty")
	}
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return "", err
	}

	name := filepath.Base(strings.TrimSpace(filePath))
	if strings.TrimSpace(originalName) != "" {
		name = filepath.Base(strings.TrimSpace(originalName))
	}
	if name == "." || name == "/" || name == "" {
		name = "telegram-media-" + time.Now().Format("20060102-150405")
	}

	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	localPath := filepath.Join(targetDir, fmt.Sprintf("%s-%d%s", base, time.Now().UnixNano(), ext))

	downloadURL := fmt.Sprintf("https://api.telegram.org/file/bot%s/%s", cfg.BotToken, filePath)
	resp, err := (&http.Client{Timeout: 120 * time.Second}).Get(downloadURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("download status %d: %s", resp.StatusCode, string(body))
	}

	out, err := os.Create(localPath)
	if err != nil {
		return "", err
	}
	defer out.Close()

	if _, err := io.Copy(out, resp.Body); err != nil {
		return "", err
	}
	return localPath, nil
}
