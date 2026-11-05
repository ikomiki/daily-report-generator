# daily-report-generator

GitHub と Bitbucket から期間内の自分のコミットを集め、ブランチ単位で `claude -p` (Haiku) に要約させて、Obsidian のデイリーノートの `Yesterday's work` 見出し (`OBSIDIAN_HEADING` で変更可) に追記するスクリプト。

当日のノートに当日の作業を書くと、徹夜で日付を跨いだ作業の扱いが難しい。そのため前日 3:00 JST 以降の作業を、翌日 (実行日) のノートに書く。

## 出力形式

```markdown
### ユーザ名または組織名 (GitHub / BitBucket)
#### リポジトリ名
##### ブランチ名
- 要約 (箇条書き)
```

- 対象は全ブランチの自分のコミット。マージコミットは除外する
- 同じコミットが複数ブランチにある場合は、デフォルトブランチ以外のブランチに帰属させる

## 前提条件

### 共通

- macOS (`date -v` など BSD 版コマンドを使用)
- `bash`, `curl`, `jq`
- [Claude Code](https://claude.com/claude-code) (`claude` コマンド) のインストールとログイン
  - 要約に `claude -p --model haiku` を使う
- [Obsidian](https://obsidian.md/) の CLI (`obsidian` コマンド)
  - Obsidian の設定で CLI を有効にし、Obsidian を起動しておく
  - デイリーノートに追記先の見出し (デフォルト `## Yesterday's work`) があること

### GitHub を対象にする場合

- [GitHub CLI](https://cli.github.com/) (`gh`) のインストールとログイン

  ```sh
  gh auth login
  ```

- 組織のリポジトリを読むため、トークンに `repo` と `read:org` スコープが必要

### Bitbucket を対象にする場合

- Bitbucket の API トークン (リポジトリの読み取り権限)。Bearer 認証で使う
- 自分のコミットはコミットのメールアドレスで判定する。`git config --global user.email` と異なるアドレスでコミットしている場合は `BB_EMAIL` で指定する (空白区切りで複数指定可)

## 設定

`daily_report.sh` と同じディレクトリに `.env` を置く。

```sh
# 対象サービス (空白区切り)。未指定なら警告を出して GITHUB のみ
TARGET_SERVICES="GITHUB BITBUCKET"

# GitHub: 個人リポジトリに加えて調べる組織 (空白区切り、空でも可)
GITHUB_ORGS=your-github-org

# Bitbucket
BITBUCKET_WORKSPACE=your-bitbucket-workspace
BITBUCKET_API_TOKEN=<API トークン>
# 複数指定するときは引用符で囲む (囲まないとシェルがコマンドとして実行しようとする)
BB_EMAIL="a@example.com b@example.com"
```

`.env` の値よりコマンドラインで渡した環境変数が優先される。

## 使い方

```sh
./daily_report.sh
```

| 環境変数 | 説明 | デフォルト |
|---|---|---|
| `SINCE_EPOCH` | 集計開始時刻 (UNIX 秒) | 前日 3:00 JST |
| `OBSIDIAN_HEADING` | 追記先の見出し名 (`.env` でも指定可) | `Yesterday's work` |
| `DRY_RUN` | 値があれば Obsidian に追記せず表示のみ | なし |
| `BB_EMAIL` | Bitbucket で自分と判定するメールアドレス (空白区切りで複数指定可。例: `"a@example.com b@example.com"`) | `git config --global user.email` |

例: 月曜 3:00 JST 以降を、Obsidian に書かずに確認する

```sh
DRY_RUN=1 SINCE_EPOCH=$(TZ=Asia/Tokyo date -j -f "%Y-%m-%d %H:%M:%S" "2026-11-02 03:00:00" +%s) ./daily_report.sh
```

## 定期実行 (macOS / launchd)

毎朝 9:00 に実行する例。

### 1. plist を作成する

`~/Library/LaunchAgents/com.example.daily-report.plist` を作成する。`/Users/you/...` は自分の環境のパスに置き換える。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.daily-report</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/you/daily-report-generator/daily_report.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/Users/you/.local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/Users/you/Library/Logs/daily-report.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/you/Library/Logs/daily-report.log</string>
</dict>
</plist>
```

- パスはすべて絶対パスで書く。launchd は `~` や `$HOME` を展開しないため、`~` を使うと起動に失敗する (`last exit code = 78: EX_CONFIG`)
- launchd の PATH は `/usr/bin:/bin:/usr/sbin:/sbin` だけなので、`claude`・`gh`・`obsidian`・bash 4 以降が入っているディレクトリを `PATH` に含める。場所は `command -v claude gh obsidian bash` で確認できる
- ログの出力先ディレクトリは事前に存在している必要がある

### 2. 登録する

```sh
plutil -lint ~/Library/LaunchAgents/com.example.daily-report.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.daily-report.plist
```

plist を書き換えたときは、一度 `bootout` してから `bootstrap` し直す。

```sh
launchctl bootout gui/$(id -u)/com.example.daily-report
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.daily-report.plist
```

### 3. 確認する

```sh
# 登録状態と前回の終了コード (0 なら成功)
launchctl print gui/$(id -u)/com.example.daily-report | grep -E "^\s+(state|runs|last exit code) ="

# 実行ログ
tail -n 50 ~/Library/Logs/daily-report.log
```

`launchctl kickstart gui/$(id -u)/com.example.daily-report` で即時実行できる。ただしデイリーノートに追記されるので、試すだけなら plist の `EnvironmentVariables` に `DRY_RUN` を一時的に追加する。

### 解除する

```sh
launchctl bootout gui/$(id -u)/com.example.daily-report
rm ~/Library/LaunchAgents/com.example.daily-report.plist
```

### launchd の動作について

- 9:00 にスリープしていた場合は、復帰時に 1 回実行される。電源が切れていた場合は実行されない
- 実行時に Obsidian が起動していないと、追記に失敗する

## 注意

- 同じ日に複数回実行すると、デイリーノートに重複して追記される
- Bitbucket は更新されたリポジトリ・ブランチを先頭 100 件までしか見ない
