{{flutter_js}}
{{flutter_build_config}}

// A release build sets this version and registers the full shell worker.
// flutter run uses its media-only mode so hot reload stays network-backed.
const ramificaServiceWorkerVersion = {{flutter_service_worker_version}};

if (ramificaServiceWorkerVersion == null) {
  if (!("serviceWorker" in navigator)) {
    _flutter.loader.load();
  } else {
    const registration = navigator.serviceWorker
      .register("sw.js?media-only=1")
      .then(function () { return navigator.serviceWorker.ready; })
      .catch(function () {});
    // A failed or slow registration must never prevent the app from starting.
    Promise.race([
      registration,
      new Promise(function (resolve) { setTimeout(resolve, 1500); }),
    ]).then(function () { _flutter.loader.load(); });
  }
} else {
  _flutter.loader.load({
    serviceWorkerSettings: {
      serviceWorkerVersion: ramificaServiceWorkerVersion,
      serviceWorkerUrl: "sw.js?v=" + ramificaServiceWorkerVersion,
    },
  });
}
