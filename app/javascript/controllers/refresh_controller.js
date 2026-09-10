import { Controller } from "@hotwired/stimulus"

// 実行中のジョブを追いかける。
//
// meta http-equiv="refresh" は使えない。パースした時点でブラウザ側にタイマーが
// 仕掛かり、Turbo で別のページに移っても消えないので、あとから元の URL に
// 引き戻される。Stimulus なら要素が DOM から外れた時点で disconnect が呼ばれる。
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => this.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  reload() {
    // 見ていないタブを更新しても意味がない
    if (document.hidden) return

    Turbo.visit(window.location.href, { action: "replace" })
  }
}
