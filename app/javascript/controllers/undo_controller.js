import { Controller } from "@hotwired/stimulus"

// Undo toast: SPEC.md §3.3 says a delete stays undoable for five seconds.
// Turbo replaces the page on redirect, so the toast that arrives in the flash
// gets its own countdown and dismisses itself.
export default class extends Controller {
  static values = { seconds: { type: Number, default: 5 } }

  connect() {
    this.timer = setTimeout(() => this.dismiss(), this.secondsValue * 1000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  dismiss() {
    this.element.classList.add("is-leaving")
    setTimeout(() => this.element.remove(), 160)
  }
}
