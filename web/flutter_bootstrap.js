{{flutter_js}}
{{flutter_build_config}}

// A release build sets this version and registers sw.js.
// flutter run leaves it null and must not install a worker over the dev server.
const ramificaServiceWorkerVersion = {{flutter_service_worker_version}};

if (ramificaServiceWorkerVersion == null) {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.getRegistrations().then(function (registrations) {
      registrations.forEach(function (registration) {
        registration.unregister();
      });
    });
  }
  _flutter.loader.load();
} else {
  _flutter.loader.load({
    serviceWorkerSettings: {
      serviceWorkerVersion: ramificaServiceWorkerVersion,
      serviceWorkerUrl: "sw.js?v=" + ramificaServiceWorkerVersion,
    },
  });
}
