# ワーカーのセットアップ

自宅 VM で `bin/worker` を動かすまでの手順。**なぜこの形なのかは設計書にある**ので、ここでは手順だけ書く。
基準は「数ヶ月後の自分が VM を作り直せること」。

## 前提

- VM に Ruby と Docker が入っていること。bundler も Gemfile.lock の同期も要らない（ワーカーは stdlib だけで書かれている）
- VM に inbound の口を開けないこと。ワーカーは outbound のみ
- VM に Tailscale を入れないこと。境界は VM の firewall 一箇所

## 1. トークンを発行する

VPS の `/admin/workers` で `worker_id`（例: `home-vm-01`）を入れて発行する。
**平文はその場で 1 度だけ表示される。** 閉じたら二度と見られないので、無くしたら再発行する。

## 2. VM 側を用意する

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin mcprb
sudo usermod -aG docker mcprb

sudo git clone <このリポジトリ> /opt/mcprb
cd /opt/mcprb && sudo git rev-parse HEAD | sudo tee /opt/mcprb/REVISION

sudo install -d -m 0755 /etc/mcprb
sudo cp /opt/mcprb/worker/config.example.yml /etc/mcprb/config.yml
sudo $EDITOR /etc/mcprb/config.yml          # worker_id と endpoint を書く

printf '%s' '<発行されたトークン>' | sudo tee /etc/mcprb/token > /dev/null
sudo chmod 0400 /etc/mcprb/token
sudo chown root:root /etc/mcprb/token
```

`/etc/mcprb/token` は root しか読めない。ワーカーには systemd の `LoadCredential=` で渡るので、
`mcprb` ユーザーがこのファイルを直接読める必要はない。

## 3. firewall

ここだけは落とせない。**LAN 遮断を firewall 側で確実に効かせる。**

| 経路 | ポリシー |
|---|---|
| コンテナ用ブリッジ → インターネット | 許可（build フェーズに必要） |
| コンテナ用ブリッジ → LAN | 全拒否 |
| VM 自身の outbound | VPS のエンドポイントのみ許可 |
| inbound | 全拒否 |

nftables なら、docker のブリッジ（既定では `docker0`、`172.17.0.0/16`）から
RFC1918 のアドレスへ出る通信を落とす。

```
table inet mcprb {
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "docker0" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
  }
}
```

実行コンテナは `--network none` で走るのでそもそも外に出られない。ここで守っているのは
**build フェーズ**で、Blueprint のレビューと合わせて 2 段で効かせる。

## 4. unit を置いて起動する

```sh
sudo cp /opt/mcprb/deploy/mcprb-worker.service /etc/systemd/system/
sudo cp /opt/mcprb/deploy/mcprb-prune.service /etc/systemd/system/
sudo cp /opt/mcprb/deploy/mcprb-prune.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mcprb-worker.service
sudo systemctl enable --now mcprb-prune.timer
```

## 5. 動作確認

```sh
# 1 行 1 イベントで出る
sudo journalctl -u mcprb-worker -f
```

`/admin/workers` にインスタンスが出て、最終 heartbeat が 30 秒ごとに更新されていれば動いている。
commit がサーバー側とずれていると行に警告が出る。

素の ruby で読めるかどうかだけは、VM に置く前に確かめられる。

```sh
ruby -Ilib -I. -e 'require "worker/runner"'
```

これが落ちるときは、ワーカーか `lib/protocol` に ActiveSupport の拡張（`blank?`、`1.hour` など）が
混ざっている。開発機では Rails 経由で通ってしまうので、人間のレビューでは捕まえられない。

## 更新する

```sh
cd /opt/mcprb
sudo git pull
sudo git rev-parse HEAD | sudo tee REVISION
sudo systemctl restart mcprb-worker
```

再起動時はワーカーが `/deregister` を打つので、走りかけのジョブは即座にキューへ戻る。
リースのタイムアウトも heartbeat の失効判定も待たない。

## 困ったとき

| 症状 | 見るところ |
|---|---|
| ジョブが `queued` のまま動かない | `/admin/workers` にインスタンスが出ているか。`drain` が立っていないか（protocol_version のずれ） |
| `policy_rejected` が返る | `/etc/mcprb/config.yml` の上限と、Blueprint の context のパス |
| `image_build_failed` | `job_results.stderr` の末尾にビルドログが入っている |
| 401 が続く | トークンが失効していないか（`/admin/workers`）。`/etc/mcprb/token` の中身に改行が混ざっていないか |
| コンテナが残る | `docker ps -a --filter label=mcprb.job`。unit の起動前・停止後の掃除で回収される |
