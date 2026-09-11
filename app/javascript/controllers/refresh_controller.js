import { Controller } from "@hotwired/stimulus"

// Follows a job while it runs.
//
// meta http-equiv="refresh" cannot do this. Parsing it arms a timer in the browser
// that survives a Turbo visit to another page, and pulls the reader back to the old
// URL later on. With Stimulus, disconnect fires the moment the element leaves the DOM.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => this.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  reload() {
    // Refreshing a tab nobody is looking at is pointless
    if (document.hidden) return

    Turbo.visit(window.location.href, { action: "replace" })
  }
}
