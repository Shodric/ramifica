const mediaOnly = new URL(self.location.href).searchParams.has("media-only");

// Development uses only the media handler, leaving Flutter's hot reload and
// freshly served code outside the worker's shell cache.
if (!mediaOnly) {
  // A schema change requires a new running client, including already-open tabs.
  self.addEventListener("activate", function (event) {
    event.waitUntil(self.clients.matchAll({type: "window"}).then(function (clients) {
      return Promise.all(clients.map(function (client) { return client.navigate(client.url); }));
    }));
  });
}

self.addEventListener("install", function (event) {
  event.waitUntil(self.skipWaiting());
});
self.addEventListener("activate", function (event) {
  event.waitUntil(self.clients.claim());
});

// Ramifica shell. Workbox is loaded from the CDN on first install.
// The browser keeps the imported script with this worker after that.
// The local media handler remains available when the CDN is unreachable.
if (!mediaOnly) {
  try {
    importScripts(
      "https://storage.googleapis.com/workbox-cdn/releases/7.3.0/workbox-sw.js",
    );
  } catch (error) {
    // Media caching still works if the shell library cannot be loaded.
  }
}

if (self.workbox) {
  const shellRevision =
    new URL(self.location.href).searchParams.get("v") || "dev";
  workbox.core.skipWaiting();
  workbox.core.clientsClaim();

  const shellPrecache = [
    { url: "/main.dart.js", revision: shellRevision },
    { url: "/flutter.js", revision: shellRevision },
    { url: "/flutter_bootstrap.js", revision: shellRevision },
    { url: "/version.json", revision: shellRevision },
    { url: "/manifest.webmanifest", revision: shellRevision },
    { url: "/favicon.png", revision: shellRevision },
    { url: "/icons/Icon-192.png", revision: shellRevision },
    { url: "/icons/Icon-512.png", revision: shellRevision },
    { url: "/icons/Icon-maskable-192.png", revision: shellRevision },
    { url: "/icons/Icon-maskable-512.png", revision: shellRevision },
    { url: "/canvaskit/canvaskit.js", revision: shellRevision },
    { url: "/canvaskit/canvaskit.wasm", revision: shellRevision },
    { url: "/canvaskit/chromium/canvaskit.js", revision: shellRevision },
    { url: "/canvaskit/chromium/canvaskit.wasm", revision: shellRevision },
    { url: "/assets/AssetManifest.bin", revision: shellRevision },
    { url: "/assets/AssetManifest.bin.json", revision: shellRevision },
    { url: "/assets/FontManifest.json", revision: shellRevision },
    { url: "/assets/fonts/MaterialIcons-Regular.otf", revision: shellRevision },
    {
      url: "/assets/packages/cupertino_icons/assets/CupertinoIcons.ttf",
      revision: shellRevision,
    },
    {
      url: "/assets/assets/fonts/PlusJakartaSans-Regular.woff2",
      revision: shellRevision,
    },
    {
      url: "/assets/assets/fonts/PlusJakartaSans-SemiBold.woff2",
      revision: shellRevision,
    },
    {
      url: "/assets/assets/fonts/PlusJakartaSans-Bold.woff2",
      revision: shellRevision,
    },
    {
      url: "/assets/assets/fonts/Montserrat-Bold.woff2",
      revision: shellRevision,
    },
  ];

  workbox.precaching.precacheAndRoute(shellPrecache);

  // Document navigations, including /story/**, open the SPA.
  workbox.routing.registerRoute(
    function (context) {
      return context.request.mode === "navigate";
    },
    new workbox.strategies.NetworkFirst({
      cacheName: "shell",
      networkTimeoutSeconds: 3,
    }),
  );

  workbox.routing.registerRoute(
    function (context) {
      const host = context.url.hostname;
      return (
        host.endsWith("cloudfunctions.net") ||
        host.endsWith("cloudfunctions.googleapis.com")
      );
    },
    new workbox.strategies.NetworkOnly(),
  );
}

// Registered after the shell routes so their precached assets keep priority.
// This local script also works without the Workbox CDN.
importScripts("media_cache.js");
