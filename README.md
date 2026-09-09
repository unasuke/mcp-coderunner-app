# mcprb

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
bin/mcp_stdio        フェーズ 2 限りの暫定 stdio サーバー
deploy/              systemd unit と Caddyfile の例
docs/worker-setup.md VM 側のセットアップ手順
```

## 開発環境

```sh
bin/setup            # 依存インストール + db:prepare + 開発サーバ
bin/rails test       # Rails 側のテスト
bin/ci               # lint・セキュリティ・テストを一通り

# ワーカーは Rails を読まない。素の ruby で走らせる
ruby -Ilib -I. -e 'require "worker/runner"'
ruby -Ilib -I. worker/test/policy_test.rb

# docker を実際に回す E2E（遅い）
MCPRB_E2E=1 ruby -Ilib -I. worker/test/e2e_test.rb
```

`bin/mcp_stdio` は Claude Desktop から stdio で繋いで単発実行するためのもの。

```json
{
  "mcpServers": {
    "mcprb-local": { "command": "/path/to/mcp-sandbox-app/bin/mcp_stdio" }
  }
}
```

## 環境変数

| 変数 | 用途 |
|---|---|
| `MCPRB_BASE_URL` | 公開 URL。review_url と OAuth のメタデータに使う |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub ログイン |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | 最初のログインで admin になるログイン名 |
| `KAMAL_VERSION` | デプロイしたリビジョン。ワーカーとのずれの検知に使う |

## デプロイ

VPS は Kamal、ワーカーは systemd。`docs/worker-setup.md` を参照。
既存の Caddy が 80/443 を持つ前提で、Kamal 側の proxy は無効にしてある。
