import { Controller } from "@hotwired/stimulus"

// Web Push: the only way to hear that a Blueprint is waiting without keeping the
// page open.
//
// On iOS this works from a Home Screen install and nowhere else -- Safari does not
// offer PushManager to an ordinary tab, so the button says that instead of failing
// at the moment it is pressed.
export default class extends Controller {
  static values = { publicKey: String }
  static targets = ["button", "state"]

  async connect() {
    if (!this.supported) {
      this.buttonTarget.hidden = true
      this.stateTarget.textContent = this.iOSTab
        ? "iPhone では、ホーム画面に追加して開くと通知を受け取れます"
        : "この環境は通知に対応していません"
      return
    }

    this.show(await this.subscription())
  }

  get supported() {
    return "serviceWorker" in navigator && "PushManager" in window && window.isSecureContext
  }

  // iOS hands PushManager only to a standalone window
  get iOSTab() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.navigator.standalone
  }

  async toggle() {
    this.buttonTarget.disabled = true

    try {
      const existing = await this.subscription()
      this.show(existing ? await this.unsubscribe(existing) : await this.subscribe())
    } catch (error) {
      this.stateTarget.textContent = `通知を設定できませんでした: ${error.message}`
    } finally {
      this.buttonTarget.disabled = false
    }
  }

  async subscribe() {
    if (await Notification.requestPermission() !== "granted") {
      throw new Error("ブラウザ側で通知が拒否されています")
    }

    const registration = await this.registration()
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: decodeKey(this.publicKeyValue)
    })

    const keys = subscription.toJSON().keys
    await this.send("POST", {
      endpoint: subscription.endpoint, p256dh: keys.p256dh, auth: keys.auth
    })

    return subscription
  }

  async unsubscribe(subscription) {
    await this.send("DELETE", { endpoint: subscription.endpoint })
    await subscription.unsubscribe()

    return null
  }

  async subscription() {
    return (await this.registration()).pushManager.getSubscription()
  }

  async registration() {
    await navigator.serviceWorker.register("/service-worker")

    return navigator.serviceWorker.ready
  }

  async send(method, body) {
    const response = await fetch("/admin/push_subscription", {
      method,
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
      },
      body: JSON.stringify(body)
    })

    if (!response.ok) throw new Error(`サーバーが ${response.status} を返しました`)
  }

  show(subscription) {
    this.buttonTarget.textContent = subscription ? "通知を止める" : "このブラウザで通知を受け取る"
    this.stateTarget.textContent = subscription ? "レビュー待ちが出たら通知します" : ""
  }
}

// The VAPID public key travels as urlsafe base64 and subscribe() wants bytes
function decodeKey(value) {
  const padded = (value + "=".repeat((4 - value.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(padded)

  return Uint8Array.from([...raw].map((char) => char.charCodeAt(0)))
}
