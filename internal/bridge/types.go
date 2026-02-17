package bridge

type telegramUpdate struct {
	UpdateID int64            `json:"update_id"`
	Message  *telegramMessage `json:"message"`
}

type telegramMessage struct {
	MessageID int64                `json:"message_id"`
	Chat      telegramChat         `json:"chat"`
	From      *telegramUser        `json:"from"`
	Text      string               `json:"text"`
	Caption   string               `json:"caption"`
	Photo     []telegramPhotoSize  `json:"photo"`
	Voice     *telegramFileRef     `json:"voice"`
	Audio     *telegramFileRef     `json:"audio"`
	Video     *telegramVideoRef    `json:"video"`
	VideoNote *telegramFileRef     `json:"video_note"`
	Document  *telegramDocumentRef `json:"document"`
}

type telegramChat struct {
	ID int64 `json:"id"`
}

type telegramUser struct {
	ID int64 `json:"id"`
}

type telegramFileRef struct {
	FileID string `json:"file_id"`
}

type telegramVideoRef struct {
	FileID string `json:"file_id"`
}

type telegramDocumentRef struct {
	FileID   string `json:"file_id"`
	FileName string `json:"file_name"`
	MimeType string `json:"mime_type"`
}

type telegramPhotoSize struct {
	FileID string `json:"file_id"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

type bridgeConfig struct {
	BotToken           string
	AllowedUserID      int64
	ParentPID          int
	AgentProvider      string
	AgentBin           string
	AgentArgs          string
	AgentModel         string
	AgentSupportsImage bool
	CodexBin           string
	CodexWorkdir       string
	TmpDir             string
	ImageDir           string
	CodexModel         string
	CodexSandbox       string
	WhisperPythonBin   string
	WhisperScript      string
	WhisperModel       string
	WhisperLanguage    string
	WhisperCompute     string
	MemoryFile         string
	TimeoutSec         int
	MaxReplyChars      int
	ChatLogFile        string
	SessionStoreFile   string
}

type mediaInput struct {
	Kind         string
	FileID       string
	UserHint     string
	OriginalName string
}

type imageInput struct {
	FileID   string
	UserHint string
}

type mediaProcessResult struct {
	Output       string
	UserText     string
	MediaPath    string
	BotMediaPath string
}
