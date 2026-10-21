# PR Watcher

macOS 選單列小工具，追蹤 Azure DevOps 上的 Pull Request，有變化時跳系統通知。

## 功能

- 貼上 PR 連結就開始追蹤，支援 `https://dev.azure.com/{org}/...` 和 `https://{org}.visualstudio.com/...` 兩種網址。
- 每隔一段時間（5／10／20／30／60 分鐘可選，預設 20）自動檢查，偵測到變化就發通知，例如狀態改變、有人投票或留言。點通知會直接在瀏覽器打開該 PR。
- 清單會列出每個 PR 的標題、狀態（Active／Draft／Completed／Abandoned）、各 reviewer 的投票和最近的變化。
- 有未讀變化時，選單列圖示會出現小圓點。
- 可以暫停自動檢查，暫停時圖示會變暗，但仍可手動重新整理。
- 電腦睡眠喚醒後，如果錯過了排定的檢查會立即補做一次。
- 可設定登入時自動啟動。

## 需求

- macOS 13 以上
- Xcode 或 Command Line Tools（需要 Swift 5.9 以上）
- Azure DevOps Personal Access Token，權限只需要 **Code (Read)**

## 建置與安裝

```bash
./build.sh            # 產生 build/PRWatcher.app
./build.sh install    # 另外複製到 ~/Applications 並啟動
```

App 使用 ad-hoc 簽章（`codesign --sign -`），只適合在自己的電腦上使用。

## 使用方式

1. 點選單列上的圖示，第一次開啟會顯示設定區，貼上 PAT。
2. 在「貼上 PR 連結」欄位貼上 Azure DevOps 的 PR 網址，按「追蹤」。
3. 點清單中的 PR 會在瀏覽器開啟並標為已讀；滑鼠移上去按 ✕ 可以停止追蹤。

## 資料存放位置

| 資料 | 位置 |
|---|---|
| PAT | macOS 鑰匙圈 |
| 追蹤中的 PR 清單 | `~/Library/Application Support/PRWatcher/prs.json` |
| 檢查間隔、暫停狀態 | `UserDefaults` |

PAT 不會寫進任何檔案，也不在這個 repo 裡。

## 專案結構

```
Sources/PRWatcher/
  App.swift          選單列圖示、彈出視窗 UI、通知處理
  Store.swift        追蹤清單、定時檢查、鑰匙圈存取
  AzureDevOps.swift  解析 PR 網址、呼叫 Azure DevOps REST API、比對變化
  Icon.swift         選單列圖示
Info.plist           App 設定（LSUIElement：不在 Dock 顯示）
build.sh             建置 .app 並簽章
```
