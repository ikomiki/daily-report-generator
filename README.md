# daily-report-generator

GitHub と Bitbucket から期間内の自分のコミットを集め、ブランチ単位で `claude -p` (Haiku) に要約させて、Obsidian のデイリーノートの `Yesterday's work` 見出しに追記するスクリプト。

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
  - デイリーノートに `## Yesterday's work` 見出しがあること

### GitHub を対象にする場合

- [GitHub CLI](https://cli.github.com/) (`gh`) のインストールとログイン

  ```sh
  gh auth login
  ```

- 組織のリポジトリを読むため、トークンに `repo` と `read:org` スコープが必要

### Bitbucket を対象にする場合

- Bitbucket の API トークン (リポジトリの読み取り権限)。Bearer 認証で使う
- 自分のコミットはコミットのメールアドレスで判定する。`git config --global user.email` と異なるアドレスでコミットしている場合は `BB_EMAIL` で指定する

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
```

`.env` の値よりコマンドラインで渡した環境変数が優先される。

## 使い方

```sh
./daily_report.sh
```

| 環境変数 | 説明 | デフォルト |
|---|---|---|
| `SINCE_EPOCH` | 集計開始時刻 (UNIX 秒) | 前日 3:00 JST |
| `DRY_RUN` | 値があれば Obsidian に追記せず表示のみ | なし |
| `BB_EMAIL` | Bitbucket で自分と判定するメールアドレス | `git config --global user.email` |

例: 月曜 3:00 JST 以降を、Obsidian に書かずに確認する

```sh
DRY_RUN=1 SINCE_EPOCH=$(TZ=Asia/Tokyo date -j -f "%Y-%m-%d %H:%M:%S" "2026-11-02 03:00:00" +%s) ./daily_report.sh
```

## 注意

- 同じ日に複数回実行すると、デイリーノートに重複して追記される
- Bitbucket は更新されたリポジトリ・ブランチを先頭 100 件までしか見ない
