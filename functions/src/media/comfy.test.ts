import {strict as assert} from "assert";
import {test} from "node:test";
import {ComfyClient, textToImageWorkflow} from "./comfy";

test("textToImageWorkflow builds a stock API workflow", () => {
  const workflow = textToImageWorkflow(
    {
      checkpoint: "model.safetensors",
      steps: 20,
      cfg: 7,
      sampler: "euler",
      scheduler: "normal",
    },
    {prompt: "A stone temple gate at dawn.", width: 480, height: 854, seed: 7}
  );
  const sampler = workflow["5"] as {inputs: Record<string, unknown>};
  assert.equal(sampler.inputs.seed, 7);
  assert.equal(sampler.inputs.steps, 20);
  const latent = workflow["4"] as {inputs: Record<string, unknown>};
  assert.deepEqual([latent.inputs.width, latent.inputs.height], [480, 854]);
  const positive = workflow["2"] as {inputs: Record<string, string>};
  assert.equal(positive.inputs.text, "A stone temple gate at dawn.");
});

test("textToImage polls history and downloads the image", async () => {
  const seen: string[] = [];
  let histories = 0;
  const client = new ComfyClient({
    baseUrl: "http://gpu:8188",
    fetchFn: async (url, init) => {
      seen.push(`${init?.method ?? "GET"} ${url}`);
      if (url.endsWith("/prompt")) {
        return {
          ok: true,
          status: 200,
          json: async () => ({prompt_id: "p1"}),
          arrayBuffer: async () => new ArrayBuffer(0),
          text: async () => "",
        };
      }
      if (url.includes("/history/")) {
        histories += 1;
        if (histories < 2) {
          return {
            ok: true,
            status: 200,
            json: async () => ({}),
            arrayBuffer: async () => new ArrayBuffer(0),
            text: async () => "",
          };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            p1: {
              outputs: {
                "7": {
                  images: [
                    {filename: "ramifica_1.png", subfolder: "", type: "output"},
                  ],
                },
              },
            },
          }),
          arrayBuffer: async () => new ArrayBuffer(0),
          text: async () => "",
        };
      }
      assert.match(url, /\/view\?/);
      const bytes = new Uint8Array([1, 2, 3]).buffer;
      return {
        ok: true,
        status: 200,
        json: async () => ({}),
        arrayBuffer: async () => bytes,
        text: async () => "",
      };
    },
  });
  const image = await client.textToImage({
    prompt: "A gate.",
    width: 480,
    height: 854,
    seed: 1,
  });
  assert.equal(image.filename, "ramifica_1.png");
  assert.deepEqual([...image.bytes], [1, 2, 3]);
  assert.deepEqual(seen, [
    "POST http://gpu:8188/prompt",
    "GET http://gpu:8188/history/p1",
    "GET http://gpu:8188/history/p1",
    "GET http://gpu:8188/view?filename=ramifica_1.png&subfolder=&type=output",
  ]);
});

test("a rejected queue surfaces the status", async () => {
  const client = new ComfyClient({
    baseUrl: "http://gpu:8188",
    fetchFn: async () => ({
      ok: false,
      status: 500,
      json: async () => ({}),
      arrayBuffer: async () => new ArrayBuffer(0),
      text: async () => "bad checkpoint",
    }),
  });
  await assert.rejects(
    client.textToImage({prompt: "A gate.", width: 480, height: 854}),
    /500 bad checkpoint/
  );
});

test("missing base URL fails fast", () => {
  delete process.env.COMFYUI_URL;
  assert.throws(() => new ComfyClient({}), /COMFYUI_URL/);
});
