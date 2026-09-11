# 📋 mcp-coderunner-app

任意の Dockerfile とスクリプトを受け取り、リソース制限下のコンテナで実行する MCP サーバー。
Ractor の挙動確認やベンチマークを、手元の環境を汚さずに回すためのもの。

- **VPS（Rails）** — 認証・認可・MCP エンドポイント・レビュー UI
- **自宅 VM（ワーカー）** — outbound only で polling して docker を回す

自宅側に inbound の口は開けない。実行コンテナは常に `--network none`。

設計の詳細は `.claude/plans/ruby-exec-mcp-design.md`（git 管理外）にある。
このファイルには設計の説明を書かない。

## 構成

```
app/                 Rails: models, controllers, MCP ツール, /admin
lib/protocol/        Rails とワーカーが共有する DTO と定数（stdlib のみ）
worker/              docker を回す側（stdlib のみ。Rails を読まない）
bin/worker           VM で動かす常駐プロセス
deploy/              systemd unit と Caddyfile の例
docs/worker-setup.md VM 側のセットアップ手順
```

## 開発環境

```sh
bin/setup            # 依存インストール + db:prepare + 開発サーバ
bin/dev              # web + js + worker（ワーカーのトークンは初回に自動発行される）
bin/rails test       # Rails 側のテスト
bin/ci               # lint・セキュリティ・テストを一通り

# ワーカーは Rails を読まない。素の ruby で走らせる
ruby -Ilib -I. -e 'require "worker/runner"'
ruby -Ilib -I. worker/test/policy_test.rb

# docker を実際に回す E2E（遅い）
MCP_CODERUNNER_APP_E2E=1 ruby -Ilib -I. worker/test/e2e_test.rb
```

MCP クライアントからは Streamable HTTP で `http://localhost:3000/mcp` に繋ぐ。
アクセストークンは `/admin` でログインしたうえで発行する。

## 環境変数

アプリが読むもの。

| 変数 | 用途 |
|---|---|
| `MCP_CODERUNNER_APP_BASE_URL` | 公開 URL。review_url と OAuth のメタデータに使う |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub ログイン |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | 最初のログインで admin になるログイン名 |
| `KAMAL_VERSION` | デプロイしたリビジョン。ワーカーとのずれの検知に使う |

## 開発用ログイン

development では `config/mcp_coderunner_app.yml` の `allow_developer_login` が true になっており、
`/login` に「GitHub を経由せずにログイン」が出る。`dev` と入れると admin、
ほかの名前は pending になるので、承認待ちの経路も試せる。

**認可の中心（member 以上のセッションからしか認可コードを出さない）を迂回する口なので、
本番では絶対に true にしない。** 無効な環境では `/auth/developer` ごと生えない。

## デプロイ

VPS は Kamal、ワーカーは systemd（`docs/worker-setup.md`）。

イメージは**手元か CI でビルドして ghcr.io に push し、サーバーは pull するだけ**。
VPS ではビルドしない。既存の Caddy が 80/443 を持つ前提で、kamal-proxy は無効にしてある。

**実アドレスとホスト名はリポジトリに置かない。**`config/deploy.yml` は次の環境変数から読む。
手元から流すときはシェルに、CI からは secret に入れる。

| 変数 | 中身 |
|---|---|
| `DEPLOY_HOST` | VPS のアドレス |
| `MCP_CODERUNNER_APP_BASE_URL` | 公開 URL |
| `GITHUB_CLIENT_ID` / `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | GitHub ログインの設定 |
| `KAMAL_REGISTRY_PASSWORD` | ghcr.io のトークン（`write:packages` を持つ classic PAT） |
| `GITHUB_CLIENT_SECRET` / `RAILS_MASTER_KEY` | コンテナに渡す秘密（`.kamal/secrets` 経由） |

```sh
bin/kamal config     # 解決結果を確認する。デプロイ前に一度通しておくと事故が減る
bin/kamal deploy
```

### CI からのデプロイ

`main` に入って CI の全ジョブが通ると、`.github/workflows/ci.yml` の `deploy` ジョブが走る。
VPS への ssh は [opkssh](https://github.com/openpubkey/opkssh) で、**長命の秘密鍵を CI にも VPS にも置かない**。
GitHub Actions の OIDC トークンで入る。

ghcr.io への push と VPS からの pull には `GITHUB_TOKEN` を使う。ジョブの寿命だけ有効なので、
**VPS に残る資格情報も同じ時間で切れる**（パッケージを public にすれば pull に資格情報は要らなくなる）。

必要な secret:

| secret | 中身 |
|---|---|
| `DEPLOY_HOST` | VPS のアドレス |
| `DEPLOY_SSH_USER` | ssh の接続先ユーザー（未設定なら `root`） |
| `MCP_CODERUNNER_APP_BASE_URL` | 公開 URL |
| `OAUTH_GITHUB_CLIENT_ID` / `OAUTH_GITHUB_CLIENT_SECRET` | GitHub ログイン。**`GITHUB_` で始まる名前の secret は作れない**ので別名で置き、ワークフローで移し替える |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | 最初のログインで admin になるログイン名 |
| `RAILS_MASTER_KEY` | `config/master.key` の中身 |

VPS 側は opkssh を入れて、GitHub Actions を発行者として許可する。

```
# /etc/opk/providers
https://token.actions.githubusercontent.com github oidc

# /etc/opk/auth_id  （<ログインさせる Linux ユーザー> <主体> <発行者>）
root repo:unasuke/mcp-coderunner-app:ref:refs/heads/main https://token.actions.githubusercontent.com
```

`main` のワークフローからしか入れない。ブランチやフォークの CI は主体が一致しないので弾かれる。

リポジトリを public にしたらパッケージも public にしてよい。イメージの中身は
公開済みのソースなので隠す意味がなく、public にすればサーバー側は資格情報なしで
pull できる。

## ライセンス

MIT License（[LICENSE](LICENSE)）
