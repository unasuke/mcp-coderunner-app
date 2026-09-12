// Receives Web Push while nothing of this site is open. Registered from
// app/javascript/controllers/push_controller.js, served from the root so its
// scope covers the whole site.

self.addEventListener("push", async (event) => {
  const { title, options } = await event.data.json()
  event.waitUntil(self.registration.showNotification(title, options))
})

// A notification about a Blueprint is only useful if it opens the review page.
// Reuse a tab that is already there rather than piling up windows.
self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const path = event.notification.data?.path || "/"

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      for (const client of windows) {
        if (new URL(client.url).pathname === path && "focus" in client) return client.focus()
      }

      if (clients.openWindow) return clients.openWindow(path)
    })
  )
})
