# ワーカーのセットアップ

*[English](worker-setup.md)*

自宅 VM で `bin/worker` を動かすまでの手順。**なぜこの形なのかは設計書にある**ので、ここでは手順だけ書く。
基準は「数ヶ月後の自分が VM を作り直せること」。

## 前提

- **Ruby 3.3 以上**と **rootless** Docker（3 章）。ほかは要らない（bundler も Gemfile.lock の同期も不要。ワーカーは stdlib だけで書かれている）。VPS 側の Ruby と揃える必要もない。
  - 想定しているのは**ディストリの ruby パッケージ**。unit は `/usr/bin/ruby` を実行する。バージョンマネージャだと、`nologin` のシステムユーザーから辿れない場所に処理系が置かれ、セキュリティ更新も apt の手を離れる。
  - 3.3 が下限なのは、インスタンスの識別に `SecureRandom.uuid_v7` を使っているため。古い Ruby では**入ってはいるが起動時に落ちる**。
- VM に inbound の口を開けないこと。ワーカーは outbound のみ
- VM に Tailscale を入れないこと。境界は VM の firewall 一箇所

## 1. トークンを発行する

VPS の `/admin/workers` で `worker_id`（例: `home-vm-01`）を入れて発行する。
**平文はその場で 1 度だけ表示される。** 閉じたら二度と見られないので、無くしたら再発行する。

## 2. VM 側を用意する

```sh
# ホームを持たせる。rootless の daemon がイメージストアをその下に置くため。
# /home には作らない（ここに置くべきものは無く、実体は状態ファイル）
sudo useradd --system --create-home --home-dir /var/lib/mcp-coderunner-app \
  --shell /usr/sbin/nologin mcp-coderunner-app

sudo git clone <このリポジトリ> /opt/mcp-coderunner-app
cd /opt/mcp-coderunner-app && sudo git rev-parse HEAD | sudo tee /opt/mcp-coderunner-app/REVISION

sudo install -d -m 0755 /etc/mcp-coderunner-app
sudo cp /opt/mcp-coderunner-app/worker/config.example.yml /etc/mcp-coderunner-app/config.yml
sudo $EDITOR /etc/mcp-coderunner-app/config.yml          # worker_id と endpoint を書く

printf '%s' '<発行されたトークン>' | sudo tee /etc/mcp-coderunner-app/token > /dev/null
sudo chmod 0400 /etc/mcp-coderunner-app/token
sudo chown root:root /etc/mcp-coderunner-app/token
```

`/etc/mcp-coderunner-app/token` は root しか読めない。ワーカーには systemd の `LoadCredential=` で渡るので、
`mcp-coderunner-app` ユーザーがこのファイルを直接読める必要はない。

## 3. rootless Docker

daemon を root ではなく `mcp-coderunner-app` で動かす。ソケットに届くことが
「VM の root であること」と同義でなくなる。rootful の daemon に話せるワーカーは
実質 root なので、ここが今回の眼目になる。

**2 つ外すと、設計の一部が黙って成立しなくなる。**

```sh
sudo apt install -y uidmap docker-ce-rootless-extras
which dockerd-rootless-setuptool.sh          # 後者のパッケージに入っている

# subordinate id。useradd が書くのは通常アカウントのときだけで、--system では
# 書かれないので手で足す。ほかと重ならない範囲なら値は任意、幅は 65536 以上
# （最初のログインユーザーが 100000-165535 を持っていることが多い）
cat /etc/subuid /etc/subgid
sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 mcp-coderunner-app
grep ^mcp-coderunner-app: /etc/subuid /etc/subgid   # 空で返らないこと

# daemon は systemd の *user* サービスなので、ログインしていなくても user manager が動く必要がある
sudo loginctl enable-linger mcp-coderunner-app

# rootless に既定で委譲されるのは memory と pids だけ。cpu が無いと --cpus も
# bench を排他にする cpuset も「受け付けて無視」になり、適用していない
# applied_limits をワーカーが報告し続けることになる
sudo install -d /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
  | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
sudo reboot
```

再起動後、そのユーザーで daemon を入れる。ログインシェルが無いので、セッションの
環境変数は手で渡す。

```sh
uid=$(id -u mcp-coderunner-app)

# HOME も渡す。sudo は対象アカウントのものを設定しないので、
# 渡さないと "HOME needs to be set" で止まる
sudo -u mcp-coderunner-app env \
  HOME=/var/lib/mcp-coderunner-app \
  XDG_RUNTIME_DIR=/run/user/$uid \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
  PATH=/usr/bin:/bin \
  dockerd-rootless-setuptool.sh install

sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$uid \
  systemctl --user enable --now docker
```

シェル無しで動かないときは、その場だけシェルを貸す（`sudo usermod -s /bin/bash
mcp-coderunner-app`）。入れ終わったら `/usr/sbin/nologin` に戻す。

unit にソケットの場所を教え、rootful の daemon は止めておく（間違って繋がないため）。

```sh
printf 'DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$uid" \
  | sudo tee /etc/mcp-coderunner-app/worker.env

sudo systemctl disable --now docker.service docker.socket
```

### build フェーズの DNS

ホストは systemd-resolved で名前を引いており、そのスタブは `127.0.0.53` にいる。
コンテナは自分のネットワーク名前空間と自分の loopback を持つので、**そこには誰もいない**。
build の DNS クエリは出ていったまま返らず、`apt-get update` がソースごとに 20 秒ずつ
リトライして数分後に失敗する。daemon が渡せる有効なリゾルバが存在しないので、明示する。

```sh
uid=$(id -u mcp-coderunner-app)

sudo -u mcp-coderunner-app install -d /var/lib/mcp-coderunner-app/.config/docker
sudo -u mcp-coderunner-app tee /var/lib/mcp-coderunner-app/.config/docker/daemon.json > /dev/null <<'JSON'
{ "dns": ["1.1.1.1", "8.8.8.8"] }
JSON

sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user restart docker
```

これは rootless の daemon の設定。`/etc/docker/daemon.json` は rootful 用で、いまは何もしない。

```sh
printf 'FROM alpine\nRUN cat /etc/resolv.conf && nslookup deb.debian.org\n' > /tmp/df
sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker build --no-cache --progress=plain -f /tmp/df /tmp 2>&1 | tail -20
```

`--progress=plain` が要る。付けないと `RUN` の出力が表示されない。実行コンテナには
この設定は関係ない（`--network none`）。名前を引くのは build フェーズだけ。

### rootful から移行する場合

rootful のワーカーを動かしていた VM では**アカウントが既にあるので、上の `useradd` は
何もしません**。home も作られたときのままです。user manager は `/etc/passwd` の home を
見る一方、setup ツールは渡した `HOME` の下に unit を書くので、食い違うと
`Unit docker.service not found` で止まる。

```sh
sudo usermod --home /var/lib/mcp-coderunner-app mcp-coderunner-app   # -m は付けない。ツールが既にそこへ書いている
sudo gpasswd -d mcp-coderunner-app docker                            # unit はもう要求しない
sudo systemctl restart user@$(id -u mcp-coderunner-app).service      # passwd を読み直させる

# ジョブの作業ディレクトリは /run の下に置けない。rootless の daemon は自分の /run を持つ
sudo sed -i 's,^runtime_dir:.*,runtime_dir: /var/lib/mcp-coderunner-app/work,' \
  /etc/mcp-coderunner-app/config.yml
```

rootful の daemon が作ったイメージは rootless からは見えないので、最初のジョブは
Blueprint の再ビルドから始まる。

### 制限が本当に効いているか確かめる

**ここは飛ばさない。**他が全部正常に見えたまま制限だけ効いていない状態がありえて、
**適用していない制限を報告するワーカーは、動かないワーカーより悪い。**

```sh
uid=$(id -u mcp-coderunner-app)

cat /sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers
# cpu cpuset io memory pids が並ぶこと

sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker run --rm --memory 64m --cpus 1 --pids-limit 32 alpine \
  sh -c 'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max'
# 67108864 / 100000 100000 / 32 と出ること
```

どれかが `max` なら効いていない。実ジョブを流す前に委譲を直すこと。

## 4. firewall

ここだけは落とせない。**LAN 遮断を firewall 側で確実に効かせる。**

| 経路 | ポリシー |
|---|---|
| コンテナ → インターネット | 許可（build フェーズに必要） |
| **コンテナ → LAN** | **全拒否（ここだけは落とせない）** |
| VM 自身の outbound | 制限しない |
| inbound | 全拒否 |

VM 自身の outbound を絞らないのは、**build フェーズに外向きの通信路がある時点で
出口は既に開いているから**（設計 §9.2 で受け入れている）。VM 本体だけを塞いでも、
守れるものの割に更新や運用の手数が増える。守っているのは LAN への到達と inbound で、
そこは変えない。

**rootless では書き方が変わる。**フィルタすべきブリッジが無い。rootlesskit が
コンテナの通信をホストのネットワークスタックから出すので、firewall から見ると
`mcp-coderunner-app` ユーザーの通信になる。output フックで uid を見る。
`docker0` に対して書いたルール（rootful 用で、以前ここに書いてあったもの）は
**何にも一致せず、何も守らない**。

```
table inet mcp-coderunner-app {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid <uid> ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
    meta skuid <uid> ip6 daddr { fc00::/7, fe80::/10 } drop
  }
}
```

ワーカー自身も同じユーザーで動くが、LAN に用は無いので巻き込んで構わない。
LAN 上の応答するホストに対して、コンテナから確かめる。

```sh
uid=$(id -u mcp-coderunner-app)
sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker run --rm alpine sh -c 'nc -z -w2 <ルーターのアドレス> 80; echo "exit=$?"'
# exit=0 にならないこと
```

実行コンテナは `--network none` で走るのでそもそも外に出られない。ここで守っているのは
**build フェーズ**で、Blueprint のレビューと合わせて 2 段で効かせる。

## 5. unit を置いて起動する

```sh
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-worker.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mcp-coderunner-app-worker.service
sudo systemctl enable --now mcp-coderunner-app-prune.timer
```

## 6. 動作確認

```sh
# 1 行 1 イベントで出る
sudo journalctl -u mcp-coderunner-app-worker -f
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
sudo /opt/mcp-coderunner-app/deploy/update-worker.sh
```

`origin/main` に合わせて、`REVISION` を書き直し、unit を再起動する。
`git pull` ではなく `git reset --hard` なので、手元に差分が残っていても結果が一意になる。
`bundle install` は要らない（ワーカーは stdlib だけで書かれている）。

**引き金は人間か VM 側の timer が引く。VPS には引かせない。** heartbeat の `outdated` を見て
自動更新する形にすると、VPS が VM で動くコードを決められることになり、
「ワーカーは VPS を信用しない」という土台が崩れる。

戻すときは同じ手順で、`git reset --hard <SHA>` を指すようにする。ビルド成果物が無いので
チェックアウトを戻して再起動するだけで済む。

再起動時はワーカーが `/deregister` を打つので、走りかけのジョブは即座にキューへ戻る。
リースのタイムアウトも heartbeat の失効判定も待たない。

## 困ったとき

| 症状 | 見るところ |
|---|---|
| ジョブが `queued` のまま動かない | `/admin/workers` にインスタンスが出ているか。`drain` が立っていないか（protocol_version のずれ） |
| `policy_rejected` が返る | `/etc/mcp-coderunner-app/config.yml` の上限と、Blueprint の context のパス |
| `ruby: No such file or directory -- /work/script.rb` | ジョブの作業ディレクトリが `/run` の下にある。rootless の daemon は自分の `/run` を持つ（rootlesskit の `--copy-up=/run`）ので、ワーカーが書いた側は見えず、docker が空のディレクトリを代わりに mount する。`runtime_dir` を `/var/lib/mcp-coderunner-app` の下にする |
| build が固まった末に `apt-get update` で失敗する | DNS。ホストの `127.0.0.53` にコンテナからは届かない。「build フェーズの DNS」を見る |
| `image_build_failed` | `job_results.stderr` の末尾にビルドログが入っている |
| 401 が続く | トークンが失効していないか（`/admin/workers`）。`/etc/mcp-coderunner-app/token` の中身に改行が混ざっていないか |
| ビルドが `unknown flag: --tag` で落ちる | docker CLI がプラグインディレクトリを見失っている。Docker 29 では `build` は buildx プラグインが提供する。`ProtectHome=yes` によって `$HOME/.docker` が「無い」ではなく「読めない」になるのが原因で、CLI はこの 2 つを区別する。unit の `DOCKER_CONFIG` で回避しているので、古い unit のままなら置き直す |
| ジョブの制限が `applied_limits` と一致しない | cpu が委譲されていない。3 章の確認 1 行で分かる。`/etc/systemd/system/user@.service.d/` の drop-in を置いて再起動する |
| setup ツールが unit を書いた直後に `Unit docker.service not found` | `/etc/passwd` の home と、ツールに渡した `HOME` が違うディレクトリを指している。「rootful から移行する場合」を見る |
| setup ツールが subuid/subgid が無いと言って止まる | `useradd --system` は割り当てない。`sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 mcp-coderunner-app` のあと user 側の docker を再起動する |
| `Cannot connect to the Docker daemon` | `/etc/mcp-coderunner-app/worker.env` が無いか uid が違う。または user 側の daemon が動いていない: `sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$(id -u mcp-coderunner-app) systemctl --user status docker` |
| コンテナが残る | `docker ps -a --filter label=mcp-coderunner-app.job`。unit の起動前・停止後の掃除で回収される |
