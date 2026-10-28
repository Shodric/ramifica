export interface ComfyOptions {
  baseUrl: string;
  checkpoint?: string;
  steps?: number;
  cfg?: number;
  sampler?: string;
  scheduler?: string;
  seed?: number;
}

export interface StillRequest {
  prompt: string;
  width: number;
  height: number;
  seed?: number;
}

export interface ComfyImage {
  filename: string;
  subfolder: string;
  bytes: Buffer;
}

type FetchFn = (
  url: string,
  init?: {method?: string; headers?: Record<string, string>; body?: string}
) => Promise<FetchResponse>;

interface FetchResponse {
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}

/**
 * Smallest useful ComfyUI client: queue an API-format workflow, poll its
 * history, download the first output image. The transport is injectable so
 * tests run without a GPU box. Reads `COMFYUI_URL` when no base is given.
 */
export class ComfyClient {
  private readonly baseUrl: string;
  private readonly checkpoint: string;
  private readonly steps: number;
  private readonly cfg: number;
  private readonly sampler: string;
  private readonly scheduler: string;
  private readonly fetchFn: FetchFn;

  /**
   * @param {object} options Base URL, checkpoint, sampler, and transport.
   */
  constructor(
    options: {baseUrl?: string; fetchFn?: FetchFn} &
      Partial<ComfyOptions> = {}
  ) {
    const base = options.baseUrl ?? process.env.COMFYUI_URL ?? "";
    if (base === "") {
      throw new Error("COMFYUI_URL is not set.");
    }
    const env = process.env;
    this.baseUrl = base.replace(/\/+$/, "");
    this.checkpoint =
      options.checkpoint ??
      env.COMFYUI_CKPT ??
      "v1-5-pruned-emaonly.safetensors";
    this.steps = options.steps ?? Number(env.COMFYUI_STEPS ?? 20);
    this.cfg = options.cfg ?? Number(env.COMFYUI_CFG ?? 7);
    this.sampler = options.sampler ?? env.COMFYUI_SAMPLER ?? "euler";
    this.scheduler = options.scheduler ?? env.COMFYUI_SCHEDULER ?? "normal";
    this.fetchFn =
      options.fetchFn ?? ((url, init) => fetch(url, init));
  }

  /**
   * Generates one still with the bundled text-to-image workflow.
   * @param {StillRequest} still Prompt, size, and optional seed.
   * @return {Promise<ComfyImage>} The first output image.
   */
  async textToImage(still: StillRequest): Promise<ComfyImage> {
    const workflow = textToImageWorkflow(
      {
        checkpoint: this.checkpoint,
        steps: this.steps,
        cfg: this.cfg,
        sampler: this.sampler,
        scheduler: this.scheduler,
      },
      still
    );
    const queued = await this.callJson<{prompt_id?: unknown}>("/prompt", {
      prompt: workflow,
    });
    if (typeof queued.prompt_id !== "string" || queued.prompt_id === "") {
      throw new Error("ComfyUI did not queue the prompt.");
    }
    return this.waitForImage(queued.prompt_id);
  }

  /**
   * @param {string} promptId Queued prompt id.
   * @return {Promise<ComfyImage>} The first output image.
   */
  private async waitForImage(promptId: string): Promise<ComfyImage> {
    const deadline = Date.now() + 10 * 60 * 1000;
    for (;;) {
      const history = await this.callJson<HistoryResponse>(
        `/history/${promptId}`
      );
      const outputs = history[promptId]?.outputs ?? {};
      for (const output of Object.values(outputs)) {
        const image = output.images?.[0];
        if (image) return this.download(image);
      }
      if (Date.now() > deadline) {
        throw new Error(`ComfyUI timed out on ${promptId}.`);
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }

  /**
   * @param {HistoryImage} image Image entry from the history.
   * @return {Promise<ComfyImage>} The downloaded bytes.
   */
  private async download(image: HistoryImage): Promise<ComfyImage> {
    const query = new URLSearchParams({
      filename: image.filename,
      subfolder: image.subfolder,
      type: image.type,
    }).toString();
    const response = await this.fetchFn(`${this.baseUrl}/view?${query}`);
    if (!response.ok) {
      throw new Error(`ComfyUI download failed: ${response.status}.`);
    }
    return {
      filename: image.filename,
      subfolder: image.subfolder,
      bytes: Buffer.from(await response.arrayBuffer()),
    };
  }

  /**
   * @param {string} path API path.
   * @param {unknown} body Optional JSON body.
   * @return {Promise<T>} The parsed response.
   */
  private async callJson<T>(path: string, body?: unknown): Promise<T> {
    const init: {
      method: string;
      headers: Record<string, string>;
      body?: string;
    } = {
      method: body === undefined ? "GET" : "POST",
      headers: {"Content-Type": "application/json"},
    };
    if (body !== undefined) init.body = JSON.stringify(body);
    const response = await this.fetchFn(`${this.baseUrl}${path}`, init);
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      const message =
        `ComfyUI ${path} failed: ${response.status} ${detail}`;
      throw new Error(message.trim());
    }
    return (await response.json()) as T;
  }
}

interface HistoryImage {
  filename: string;
  subfolder: string;
  type: string;
}

interface HistoryResponse {
  [promptId: string]: {
    outputs?: Record<string, {images?: HistoryImage[]}>;
  };
}

export interface TextToImageSettings {
  checkpoint: string;
  steps: number;
  cfg: number;
  sampler: string;
  scheduler: string;
}

/**
 * API-format text-to-image workflow: checkpoint, prompts, sampler, decode,
 * save. Any stock ComfyUI install runs it; the checkpoint picks the style.
 * @param {TextToImageSettings} settings Checkpoint and sampler settings.
 * @param {StillRequest} still Prompt, size, and optional seed.
 * @return {Record<string, unknown>} The workflow prompt.
 */
export function textToImageWorkflow(
  settings: TextToImageSettings,
  still: StillRequest
): Record<string, unknown> {
  const seed = still.seed ?? Math.floor(Math.random() * 2 ** 31);
  return {
    "1": {
      class_type: "CheckpointLoaderSimple",
      inputs: {ckpt_name: settings.checkpoint},
    },
    "2": {
      class_type: "CLIPTextEncode",
      inputs: {text: still.prompt, clip: ["1", 1]},
    },
    "3": {
      class_type: "CLIPTextEncode",
      inputs: {
        text: "text, watermark, logo, blurry, deformed",
        clip: ["1", 1],
      },
    },
    "4": {
      class_type: "EmptyLatentImage",
      inputs: {
        width: still.width,
        height: still.height,
        batch_size: 1,
      },
    },
    "5": {
      class_type: "KSampler",
      inputs: {
        model: ["1", 0],
        positive: ["2", 0],
        negative: ["3", 0],
        latent_image: ["4", 0],
        seed,
        steps: settings.steps,
        cfg: settings.cfg,
        sampler_name: settings.sampler,
        scheduler: settings.scheduler,
        denoise: 1,
      },
    },
    "6": {
      class_type: "VAEDecode",
      inputs: {samples: ["5", 0], vae: ["1", 2]},
    },
    "7": {
      class_type: "SaveImage",
      inputs: {images: ["6", 0], filename_prefix: "ramifica"},
    },
  };
}
