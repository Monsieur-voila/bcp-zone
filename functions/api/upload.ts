// ─────────────────────────────────────────────────────────────
//  POST /api/upload
//
//  Receives an image, video, or audio file, validates it, and
//  stores it in a PRIVATE R2 bucket. Returns the object key —
//  never a public URL.
//
//  Validation is by MAGIC BYTES, not the claimed content type.
//  A renamed executable fails here even if it says image/jpeg.
// ─────────────────────────────────────────────────────────────

const LIMITS = {
  image: 25 * 1024 * 1024,    // 25MB
  video: 150 * 1024 * 1024,   // 150MB
  audio: 25 * 1024 * 1024,    // 25MB — voice is small; 5 min ≈ 3MB
};

type Kind = "image" | "video" | "audio";

// Identify a file from its leading bytes. Returns the kind and a
// file extension, or null if it isn't something we accept.
function sniff(b: Uint8Array): { kind: Kind; ext: string } | null {
  if (b.length < 16) return null;

  // ── images ──
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff)
    return { kind: "image", ext: "jpg" };
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47)
    return { kind: "image", ext: "png" };
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38)
    return { kind: "image", ext: "gif" };
  if (b[0] === 0x42 && b[1] === 0x4d)
    return { kind: "image", ext: "bmp" };
  // TIFF
  if ((b[0] === 0x49 && b[1] === 0x49 && b[2] === 0x2a) ||
      (b[0] === 0x4d && b[1] === 0x4d && b[2] === 0x00))
    return { kind: "image", ext: "tif" };

  // RIFF container: WEBP (image) or WAV (audio)
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) {
    if (b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50)
      return { kind: "image", ext: "webp" };
    if (b[8] === 0x57 && b[9] === 0x41 && b[10] === 0x56 && b[11] === 0x45)
      return { kind: "audio", ext: "wav" };
  }

  // ISO base media (ftyp at offset 4): HEIC, MP4, MOV, M4A
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8], b[9], b[10], b[11]).toLowerCase();
    if (brand.startsWith("hei") || brand.startsWith("mif") || brand.startsWith("msf"))
      return { kind: "image", ext: "heic" };
    if (brand.startsWith("qt"))
      return { kind: "video", ext: "mov" };
    if (brand.startsWith("m4a"))
      return { kind: "audio", ext: "m4a" };
    return { kind: "video", ext: "mp4" };
  }

  // Matroska / WebM — audio or video depending on what the browser made
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3)
    return { kind: "video", ext: "webm" };

  // ── audio ──
  if (b[0] === 0x4f && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53)
    return { kind: "audio", ext: "ogg" };
  if (b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33)
    return { kind: "audio", ext: "mp3" };
  if (b[0] === 0xff && (b[1] & 0xe0) === 0xe0)
    return { kind: "audio", ext: "mp3" };
  if (b[0] === 0x66 && b[1] === 0x4c && b[2] === 0x61 && b[3] === 0x43)
    return { kind: "audio", ext: "flac" };

  return null;
}

// Strip EXIF from JPEG by dropping APP1/APP2 marker segments.
// Removes GPS coordinates and camera identifiers — a tipster
// shouldn't disclose their home location by accident.
function stripJpegExif(b: Uint8Array): Uint8Array {
  if (!(b[0] === 0xff && b[1] === 0xd8)) return b;
  const out: number[] = [0xff, 0xd8];
  let i = 2;
  while (i < b.length - 1) {
    if (b[i] !== 0xff) { out.push(...b.subarray(i)); break; }
    const marker = b[i + 1];
    // Start of scan — copy the rest verbatim.
    if (marker === 0xda) { out.push(...b.subarray(i)); break; }
    const len = (b[i + 2] << 8) | b[i + 3];
    const isMeta = marker === 0xe1 || marker === 0xe2 || marker === 0xed;
    if (!isMeta) out.push(...b.subarray(i, i + 2 + len));
    i += 2 + len;
  }
  return new Uint8Array(out);
}

export const onRequestPost: PagesFunction<{ TIPS_BUCKET: R2Bucket }> = async (ctx) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status, headers: { "content-type": "application/json" },
    });

  try {
    const form = await ctx.request.formData();
    const file = form.get("file");

    if (!(file instanceof File)) return json({ error: "No file received." }, 400);
    if (file.size === 0)         return json({ error: "That file is empty." }, 400);

    let bytes = new Uint8Array(await file.arrayBuffer());
    const id = sniff(bytes);

    if (!id) {
      return json({ error: "Only photos, video, and audio can be sent." }, 400);
    }
    if (file.size > LIMITS[id.kind]) {
      const mb = Math.round(LIMITS[id.kind] / 1048576);
      return json({ error: `That ${id.kind} is over ${mb}MB.` }, 400);
    }

    if (id.ext === "jpg") bytes = stripJpegExif(bytes);

    const key = `tips/${crypto.randomUUID()}.${id.ext}`;
    await ctx.env.TIPS_BUCKET.put(key, bytes, {
      httpMetadata: { contentType: file.type || "application/octet-stream" },
    });

    return json({ key, kind: id.kind, size: bytes.length });
  } catch {
    return json({ error: "Upload failed." }, 500);
  }
};
