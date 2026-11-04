#!/usr/bin/env bash
set -euo pipefail

# 対象期間の開始 (デフォルト: 前日 3:00 JST)。SINCE_EPOCH を渡せば上書き可能
# 当日のノートに当日の作業を書くと、徹夜で日付を跨いだ作業の扱いが難しいため、前日分を翌日のノートに書く
SINCE_EPOCH="${SINCE_EPOCH:-$(TZ=Asia/Tokyo date -v-1d -v3H -v0M -v0S +%s)}"
SINCE_ISO=$(date -u -r "$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

# .env はコマンドラインの環境変数より弱くしたいので、読み込み後に元の環境変数を戻す
CMDLINE_ENV=$(export -p)
set -a; . "$(dirname "$0")/.env"; set +a
eval "$CMDLINE_ENV"
# TARGET_SERVICES / GITHUB_ORGS は空白区切りで複数指定可
if [ -z "${TARGET_SERVICES:-}" ]; then
  echo "警告: TARGET_SERVICES が未指定のため GITHUB のみ対象にします (例: TARGET_SERVICES=\"GITHUB BITBUCKET\")" >&2
  TARGET_SERVICES=GITHUB
fi
read -ra ORGS <<< "${GITHUB_ORGS:-}"
# Bitbucket はアカウントではなくコミットのメールアドレスで自分を判定する
BB_EMAIL="${BB_EMAIL:-$(git config --global user.email)}"

# トークンを引数に直接書くと ps に出るので、ヘッダーはファイル経由で渡す
bb() { curl -sf -H @<(printf 'Authorization: Bearer %s' "$BITBUCKET_API_TOKEN") "$@"; }
uri() { jq -rn --arg s "$1" '$s | @uri'; }

# 以下の *_commits は 種別<TAB>repo<TAB>ブランチ<TAB>sha<TAB>日時<TAB>メッセージ1行目 を出す。マージコミットは除外
# 同じコミットは複数ブランチに出るので、後段で最初に出たブランチに帰属させる。
# マージ先より作業ブランチに帰属させたいので、デフォルトブランチを最後に回す
# ponytail: デフォルト以外のブランチ同士 (develop と feature 等) の帰属は処理順任せ

github_commits() {
  local me
  me=$(gh api user -q .login)
  for owner in "" "${ORGS[@]}"; do
    gh repo list $owner --limit 1000 --json nameWithOwner,pushedAt,defaultBranchRef
  done | jq -r --argjson since "$SINCE_EPOCH" \
      '.[] | select((.pushedAt | fromdate) >= $since) | [.nameWithOwner, .defaultBranchRef.name] | @tsv' \
    | while IFS=$'\t' read -r repo main; do
        { gh api --paginate "repos/$repo/branches?per_page=100" -q '.[].name' | grep -vxF "$main" || true; echo "$main"; } \
          | while read -r branch; do
              gh api --paginate "repos/$repo/commits?sha=$(uri "$branch")&author=$me&since=$SINCE_ISO&per_page=100" \
                | jq -r --arg repo "$repo" --arg branch "$branch" \
                    '.[] | select(.parents | length < 2)
                      | ["GitHub", $repo, $branch, .sha[:7], .commit.author.date, (.commit.message | split("\n")[0])] | @tsv'
            done
      done
}

bitbucket_commits() {
  local api=https://api.bitbucket.org/2.0/repositories
  # ponytail: 更新リポジトリ・ブランチは先頭 100 件まで。超えるなら next を辿る
  bb -G "$api/$BITBUCKET_WORKSPACE" --data-urlencode "q=updated_on>=$SINCE_ISO" -d pagelen=100 \
    | jq -r '.values[] | [.full_name, .mainbranch.name] | @tsv' \
    | while IFS=$'\t' read -r repo main; do
        # 先頭コミットが期間外のブランチには期間内のコミットもないので、API を呼ぶ前に除外する
        { bb "$api/$repo/refs/branches?pagelen=100&sort=-target.date" \
            | jq -r --argjson since "$SINCE_EPOCH" \
                '.values[] | select((.target.date[:19] + "Z" | fromdate) >= $since) | .name' \
            | grep -vxF "$main" || true; echo "$main"; } \
          | while read -r branch; do
              url="$api/$repo/commits/$(uri "$branch")?pagelen=100"
              while [ -n "$url" ]; do
                page=$(bb "$url")
                jq -r --arg repo "$repo" --arg branch "$branch" --arg email "$BB_EMAIL" --argjson since "$SINCE_EPOCH" \
                  '.values[] | select((.date[:19] + "Z" | fromdate) >= $since
                      and (.parents | length) < 2
                      and (.author.raw | contains("<" + $email + ">")))
                    | ["BitBucket", $repo, $branch, .hash[:7], .date, (.message | split("\n")[0])] | @tsv' <<< "$page"
                # トポロジカル順で日時は厳密に単調ではないので、ページ全体が期間外になったら打ち切る
                url=$(jq -r --argjson since "$SINCE_EPOCH" \
                  'if any(.values[]; (.date[:19] + "Z" | fromdate) >= $since) then .next // "" else "" end' <<< "$page")
              done
            done
      done
}

COMMITS=$(
  for service in $TARGET_SERVICES; do
    case $service in
      GITHUB) github_commits ;;
      BITBUCKET) bitbucket_commits ;;
      *) echo "警告: 未知のサービス $service を無視します" >&2 ;;
    esac
  done \
    | awk -F'\t' '!seen[$2 FS $4]++' \
    | sort -s -t$'\t' -k1,1 -k2,2 -k3,3 -k5,5r
)

[ -n "$COMMITS" ] || { echo "対象コミットなし" >&2; exit 0; }

PROMPT='標準入力はあるブランチでの 1 日分のコミット一覧 (短縮ハッシュ + メッセージ) です。
日報に載せる作業内容として、日本語の箇条書き (「- 」始まり、1〜5 行) で要約してください。
見出し・前置き・締めの文は書かず、箇条書きだけを出力してください。'

# ### ユーザ名 (種別) > #### リポジトリ > ##### ブランチ > 要約
REPORT=$(
  prev_owner="" prev_repo=""
  while IFS=$'\t' read -r src repo branch; do
    owner="${repo%%/*} ($src)"
    if [ "$owner" != "$prev_owner" ]; then printf '### %s\n\n' "$owner"; prev_owner=$owner; prev_repo=""; fi
    if [ "$repo" != "$prev_repo" ]; then printf '#### %s\n\n' "${repo#*/}"; prev_repo=$repo; fi
    printf '##### %s\n\n' "$branch"
    awk -F'\t' -v s="$src" -v r="$repo" -v b="$branch" '$1 == s && $2 == r && $3 == b { print $4 " " $6 }' <<< "$COMMITS" \
      | claude -p --model haiku "$PROMPT"
    echo
  done < <(cut -f1-3 <<< "$COMMITS" | awk '!seen[$0]++')
)

echo "$REPORT"

# obsidian CLI は content 中の \n を改行として解釈する
[ -n "${DRY_RUN:-}" ] || obsidian daily:append heading="Yesterday's work" content="${REPORT//$'\n'/\\n}\n"
