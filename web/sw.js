// Ramifica shell. Workbox is loaded from the CDN on first install.
// The browser keeps the imported script with this worker after that.
// If the CDN is unreachable, this file installs with no fetch handlers.
try {
  importScripts(
    "https://storage.googleapis.com/workbox-cdn/releases/7.3.0/workbox-sw.js",
  );
} catch (error) {
  // Leave the worker empty so requests stay on the network.
}

if (self.workbox) {
  const shellRevision =
    new URL(self.location.href).searchParams.get("v") || "dev";
  const thirtyDays = 30 * 24 * 60 * 60;

  // Registered before any Workbox route. A Range or mp4 request must
  // not be answered by this worker.
  self.addEventListener("fetch", function (event) {
    const url = new URL(event.request.url);
    const path = url.pathname.toLowerCase();
    if (event.request.headers.has("range") || path.endsWith(".mp4")) {
      event.stopImmediatePropagation();
    }
  });

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

  // Document navigations, including /story/**. storyPage is not deployed,
  // so that path is still this app.
  workbox.routing.registerRoute(
    function (context) {
      return context.request.mode === "navigate";
    },
    new workbox.strategies.NetworkFirst({
      cacheName: "shell",
      networkTimeoutSeconds: 3,
    }),
  );

  const cachedMedia = new workbox.cacheableResponse.CacheableResponsePlugin({
    statuses: [200],
  });

  workbox.routing.registerRoute(
    function (context) {
      return context.url.pathname.toLowerCase().endsWith(".webp");
    },
    new workbox.strategies.CacheFirst({
      cacheName: "images",
      plugins: [
        cachedMedia,
        new workbox.expiration.ExpirationPlugin({
          maxEntries: 300,
          maxAgeSeconds: thirtyDays,
        }),
      ],
    }),
  );

  workbox.routing.registerRoute(
    function (context) {
      return context.url.pathname.toLowerCase().endsWith(".m4a");
    },
    new workbox.strategies.CacheFirst({
      cacheName: "voices",
      plugins: [
        cachedMedia,
        new workbox.expiration.ExpirationPlugin({
          maxEntries: 100,
          maxAgeSeconds: thirtyDays,
        }),
      ],
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
