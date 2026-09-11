import { Controller } from "@hotwired/stimulus"

// So a value shown exactly once -- a worker's token -- does not get lost.
export default class extends Controller {
  static targets = ["source"]

  async copy(event) {
    const button = event.currentTarget
    const label = button.dataset.label || button.textContent

    try {
      await navigator.clipboard.writeText(this.sourceTarget.textContent.trim())
      button.dataset.label = label
      button.textContent = "コピーしました"
      setTimeout(() => { button.textContent = label }, 1500)
    } catch {
      button.textContent = "コピーできません。手で選択してください"
    }
  }
}
