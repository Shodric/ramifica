import assert from "node:assert/strict";
import test from "node:test";
import {readableStorageUrl} from "./storageUrl";

const saved = process.env.FIREBASE_STORAGE_EMULATOR_HOST;

/**
 * Restores the emulator host the tests mutate.
 * @return {void}
 */
const restoreHost = (): void => {
  if (saved === undefined) delete process.env.FIREBASE_STORAGE_EMULATOR_HOST;
  else process.env.FIREBASE_STORAGE_EMULATOR_HOST = saved;
};

test("emulator url uses a download token and does not sign", async () => {
  process.env.FIREBASE_STORAGE_EMULATOR_HOST = "127.0.0.1:9199";
  try {
    let signed = false;
    const url = await readableStorageUrl({
      name: "stories/s/n-end-abcd.png",
      bucket: {name: "meta-ramifica.firebasestorage.app"},
      setMetadata: async () => undefined,
      getSignedUrl: async () => {
        signed = true;
        return ["https://signed.example/x"];
      },
    });
    assert.equal(signed, false);
    const prefix =
      "http://127.0.0.1:9199/v0/b/" +
      "meta-ramifica.firebasestorage.app/o/" +
      "stories%2Fs%2Fn-end-abcd.png?alt=media&token=";
    assert.equal(url.startsWith(prefix), true);
    assert.equal(url.length > prefix.length, true);
  } finally {
    restoreHost();
  }
});

test("production url is the signed read url", async () => {
  delete process.env.FIREBASE_STORAGE_EMULATOR_HOST;
  try {
    let stamped = false;
    const url = await readableStorageUrl({
      name: "stories/s/n-end-abcd.png",
      bucket: {name: "meta-ramifica.firebasestorage.app"},
      setMetadata: async () => {
        stamped = true;
      },
      getSignedUrl: async () => ["https://signed.example/x"],
    });
    assert.equal(stamped, false);
    assert.equal(url, "https://signed.example/x");
  } finally {
    restoreHost();
  }
});
