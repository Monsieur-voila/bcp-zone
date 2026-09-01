#!/usr/bin/env bash
# Style + hidden-state fixes — run from ~/site
set -e
if [ ! -f package.json ]; then echo "ERROR: run from ~/site"; exit 1; fi
echo "Writing..."
mkdir -p src/pages/forum src/components

echo "  src/pages/tips.astro"
cat > 'src/pages/tips.astro' << 'STYLEFIX_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import AuthButton from "../components/AuthButton.astro";
import "../styles/heat.css";
import "../styles/forum.css";
---
<SiteFrame title="Tips — Blaine County Preparedness">
  <div class="inbox">
    <p class="eyebrow">Private inbox</p>
    <h1 class="h1">Tips</h1>

    <!-- Not admin: nothing to see. The page reveals nothing about
         what's here, and RLS blocks the data regardless. -->
    <div class="locked" data-locked hidden>
      <p class="locked-p">This page is for site administrators.</p>
      <AuthButton />
    </div>

    <p class="loading" data-loading>Checking…</p>

    <div class="list" data-list hidden></div>
  </div>
</SiteFrame>

<script>
  import { supabase } from "../lib/supabase";
  import { myProfile, getTips, markTipRead, archiveTip, ago, attachmentUrl } from "../lib/forum";

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const loading = document.querySelector("[data-loading]");
  const locked  = document.querySelector("[data-locked]");
  const list    = document.querySelector("[data-list]");

  let rendered = false;

  async function renderInbox() {
    if (rendered) return;

    const tips = await getTips();
    rendered = true;
    loading.hidden = true;
    locked.hidden = true;
    list.hidden = false;

    if (!tips.length) {
      list.innerHTML = `<p class="empty">Nothing yet.</p>`;
      return;
    }

    const unread = tips.filter((t) => !t.is_read).length;
    list.innerHTML = `
      <p class="count">${tips.length} message${tips.length === 1 ? "" : "s"}${
        unread ? ` · ${unread} unread` : ""
      }</p>` + tips.map((t) => `
      <article class="tip${t.is_read ? "" : " unread"}">
        <div class="tip-head">
          <span class="tip-who">${esc(t.name || "no name given")}</span>
          <span class="tip-when">${ago(t.created_at)}</span>
        </div>
        ${t.email
          ? `<a class="tip-email" href="mailto:${esc(t.email)}">${esc(t.email)}</a>`
          : `<span class="tip-noemail">no reply address</span>`}
        <div class="tip-body">${esc(t.message)}</div>
        ${(t.attachments && t.attachments.length)
          ? `<div class="tip-shots" data-shots='${JSON.stringify(t.attachments)}'></div>`
          : ""}
        <div class="tip-acts">
          <button class="tip-btn" data-read="${t.id}" data-state="${t.is_read}">
            ${t.is_read ? "Mark unread" : "Mark read"}
          </button>
          <button class="tip-btn" data-archive="${t.id}">Archive</button>
        </div>
      </article>`).join("");

    // Load attachments. Each request re-verifies admin server-side.
    for (const box of list.querySelectorAll("[data-shots]")) {
      let keys = [];
      try { keys = JSON.parse(box.dataset.shots); } catch {}
      for (const key of keys) {
        // Pick the player from the stored extension.
        const ext = String(key).split(".").pop().toLowerCase();
        const isAudio = ["m4a","mp3","wav","ogg","flac"].includes(ext);
        const isVideo = ["mp4","mov","webm"].includes(ext);

        const holder = document.createElement("div");
        holder.className = isAudio ? "tip-voice" : "tip-media";
        if (isAudio) {
          holder.innerHTML = `<span class="tip-voice-tag">voicemail</span>`;
        }
        box.appendChild(holder);

        attachmentUrl(key).then((url) => {
          if (!url) {
            holder.innerHTML = `<span class="tip-shot-fail">unavailable</span>`;
            return;
          }
          let el;
          if (isAudio) {
            el = document.createElement("audio");
            el.controls = true;
            el.className = "tip-audio";
          } else if (isVideo) {
            el = document.createElement("video");
            el.controls = true;
            el.className = "tip-video";
            el.preload = "metadata";
          } else {
            el = document.createElement("img");
            el.className = "tip-shot";
            el.alt = "attachment";
            el.loading = "lazy";
          }
          el.src = url;
          holder.appendChild(el);
        });
      }
    }

    list.querySelectorAll("[data-read]").forEach((b) =>
      b.addEventListener("click", async () => {
        await markTipRead(b.dataset.read, b.dataset.state !== "true");
        location.reload();
      }));
    list.querySelectorAll("[data-archive]").forEach((b) =>
      b.addEventListener("click", async () => {
        if (!confirm("Archive this message?")) return;
        await archiveTip(b.dataset.archive);
        location.reload();
      }));
  }

  function showLocked() {
    loading.hidden = true;
    list.hidden = true;
    locked.hidden = false;
  }

  // Check admin status against a session. Called on load AND whenever
  // the auth state changes — Supabase restores the session
  // asynchronously, so checking only on load races it and wrongly
  // locks the page for a signed-in admin.
  async function check(session) {
    if (!session?.user) {
      if (!rendered) showLocked();
      return;
    }
    const profile = await myProfile();
    if (profile?.is_admin) {
      await renderInbox();
    } else {
      showLocked();
    }
  }

  const { data } = await supabase.auth.getSession();
  await check(data.session);

  supabase.auth.onAuthStateChange((_event, session) => {
    check(session);
  });
</script>

<style>
  /* An explicit `display` beats the `hidden` attribute, so without
     this the loading, locked, and list states stack on screen. */
  [hidden] { display: none !important; }

  .inbox { max-width: 68ch; margin: 0 auto; }
  .eyebrow {
    font-family: var(--mono); font-size: 0.68rem; letter-spacing: 0.2em;
    text-transform: uppercase; color: var(--sage); margin: 0 0 0.8rem;
  }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.2rem, 6vw, 3.2rem); line-height: 1.03;
    margin: 0 0 2rem; color: var(--snowmelt);
  }
  .loading, .locked-p {
    font-family: var(--mono); font-size: 0.74rem;
    color: var(--sage); margin: 0 0 1.2rem;
  }
  .locked { display: flex; flex-direction: column; gap: 0.8rem; align-items: flex-start; }
</style>
STYLEFIX_EOF

echo "  src/pages/contact.astro"
cat > 'src/pages/contact.astro' << 'STYLEFIX_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import VoiceRecorder from "../components/VoiceRecorder.astro";
import "../styles/forum.css";
---
<SiteFrame title="Contact / Tips — Blaine County Preparedness"
           description="Send a tip, a question, or something you think we should know.">
  <div class="doc">
    <p class="eyebrow">Contact / Tips</p>
    <h1 class="h1">Send it over</h1>
    <p class="lede">
      A tip, a question, something you think the valley should know. It comes
      straight to us — privately. Nothing here is published unless we ask you
      first.
    </p>

    <div class="form" data-tipform>
      <label class="field">
        <span class="label">Your name <span class="opt">(optional)</span></span>
        <input class="input" type="text" maxlength="120"
               autocomplete="name" data-tip-name />
      </label>

      <label class="field">
        <span class="label">Email <span class="opt">(if you want a reply)</span></span>
        <input class="input" type="email" maxlength="200"
               autocomplete="email" data-tip-email />
      </label>

      <label class="field">
        <span class="label">What's on your mind</span>
        <textarea class="input area" rows="7" maxlength="5000"
                  data-tip-message></textarea>
      </label>

      <VoiceRecorder />

      <div class="field">
        <span class="label">Photos or video <span class="opt">(optional)</span></span>
        <label class="filepick">
          <input type="file" accept="image/*,video/*" multiple data-tip-files />
          <span class="filepick-btn">Choose files</span>
          <span class="filepick-hint">Photos to 25MB · video to 150MB · smaller sends faster</span>
        </label>
        <ul class="filelist" data-file-list></ul>
      </div>

      <p class="notice" data-tip-notice hidden></p>

      <button class="send" type="button" data-tip-send>Send</button>

      <p class="foot-hint">
        Sending video or audio? Mention it here and we'll write back with a
        way to get it to us.
      </p>
    </div>

    <!-- shown after a successful send -->
    <div class="thanks" data-tip-thanks hidden>
      <p class="thanks-h">Got it.</p>
      <p class="thanks-p">
        Thanks for sending that over. If you left an email, we'll be in touch.
      </p>
      <button class="again" type="button" data-tip-again>Send something else</button>
    </div>
  </div>
</SiteFrame>

<script>
  import { sendTipWithFiles, uploadFile, UPLOAD_LIMITS, kindOf } from "../lib/forum";

  const form    = document.querySelector("[data-tipform]");
  const thanks  = document.querySelector("[data-tip-thanks]");
  const nameEl  = document.querySelector("[data-tip-name]");
  const emailEl = document.querySelector("[data-tip-email]");
  const msgEl   = document.querySelector("[data-tip-message]");
  const notice  = document.querySelector("[data-tip-notice]");
  const sendBtn = document.querySelector("[data-tip-send]");
  const again   = document.querySelector("[data-tip-again]");
  const fileEl  = document.querySelector("[data-tip-files]");
  const listEl  = document.querySelector("[data-file-list]");
  const vmEl    = document.querySelector("[data-vm]");

  let chosen = [];

  const totalBytes = () => {
    const rec = vmEl && vmEl._recording ? vmEl._recording.size : 0;
    return chosen.reduce((n, f) => n + f.size, 0) + rec;
  };

  function drawList() {
    if (!chosen.length) { listEl.innerHTML = ""; return; }
    listEl.innerHTML = chosen.map((f, i) => `
      <li class="fileitem">
        <span class="fileitem-name">${f.name.replace(/[<>&"]/g, "")}</span>
        <span class="fileitem-size">${(f.size / 1048576).toFixed(1)}MB</span>
        <button type="button" class="fileitem-x" data-drop="${i}">remove</button>
      </li>`).join("");
    listEl.querySelectorAll("[data-drop]").forEach((b) =>
      b.addEventListener("click", () => {
        chosen.splice(Number(b.dataset.drop), 1);
        drawList();
      }));
  }

  fileEl.addEventListener("change", () => {
    notice.hidden = true;
    for (const f of Array.from(fileEl.files)) {
      const kind = kindOf(f);
      if (!kind) {
        notice.textContent = f.name + " isn't a photo or video.";
        notice.hidden = false; continue;
      }
      if (f.size > UPLOAD_LIMITS[kind]) {
        const mb = Math.round(UPLOAD_LIMITS[kind] / 1048576);
        notice.textContent = f.name + " is over " + mb + "MB.";
        notice.hidden = false; continue;
      }
      if (totalBytes() + f.size > UPLOAD_LIMITS.totalPerTip) {
        notice.textContent = "That's more than 250MB in one message.";
        notice.hidden = false; break;
      }
      chosen.push(f);
    }
    fileEl.value = "";
    drawList();
  });

  sendBtn.addEventListener("click", async () => {
    sendBtn.disabled = true;
    notice.hidden = true;

    // The voicemail, if there is one, uploads first.
    const queue = [];
    if (vmEl && vmEl._recording) queue.push(vmEl._recording);
    queue.push(...chosen);

    const keys = [];
    for (let i = 0; i < queue.length; i++) {
      sendBtn.textContent = queue.length === 1
        ? "Sending..."
        : "Sending " + (i + 1) + " of " + queue.length + "...";
      const res = await uploadFile(queue[i]);
      if (res.error) {
        notice.textContent = res.error;
        notice.hidden = false;
        sendBtn.disabled = false;
        sendBtn.textContent = "Send";
        return;
      }
      keys.push(res.key);
    }

    sendBtn.textContent = "Sending...";
    const res = await sendTipWithFiles(
      nameEl.value, emailEl.value, msgEl.value, keys
    );

    sendBtn.disabled = false;
    sendBtn.textContent = "Send";

    if (res.error) {
      notice.textContent = res.error;
      notice.hidden = false;
      return;
    }

    nameEl.value = ""; emailEl.value = ""; msgEl.value = "";
    chosen = []; drawList();
    if (vmEl) vmEl._recording = null;
    form.hidden = true;
    thanks.hidden = false;
  });

  again.addEventListener("click", () => {
    thanks.hidden = true;
    form.hidden = false;
    msgEl.focus();
  });
</script>

<style>
  /* An explicit `display` beats the `hidden` attribute, so without
     this, elements meant to be hidden stay on screen. */
  [hidden] { display: none !important; }


  .doc { max-width: 60ch; margin: 0 auto; }
  .eyebrow {
    font-family: var(--mono); font-size: 0.68rem; letter-spacing: 0.2em;
    text-transform: uppercase; color: var(--sage); margin: 0 0 1rem;
  }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.4rem, 7vw, 3.8rem); line-height: 1.03;
    margin: 0 0 1.2rem; color: var(--snowmelt);
  }
  .lede {
    font-family: var(--body); font-size: 1.15rem; line-height: 1.6;
    color: var(--sage); margin: 0 0 2.6rem; max-width: 52ch;
  }

  .form { display: flex; flex-direction: column; gap: 1.4rem; }
  .field { display: flex; flex-direction: column; gap: 0.5rem; }
  .label {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.08em; text-transform: uppercase; color: var(--snowmelt);
  }
  .opt { color: var(--sage); text-transform: none; letter-spacing: 0; }
  .input {
    font-family: var(--body); font-size: 1rem; color: var(--snowmelt);
    background: var(--basalt-2); border: 1px solid var(--line);
    border-radius: 3px; padding: 0.75rem 0.85rem;
  }
  .input:focus { border-color: var(--oxide); outline: none; }
  .area { resize: vertical; line-height: 1.55; }

  .notice {
    font-family: var(--mono); font-size: 0.72rem;
    color: #d93b1f; margin: 0;
  }

  .send {
    align-self: flex-start;
    font-family: var(--mono); font-size: 0.76rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--basalt); background: var(--oxide);
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.75rem 1.6rem; cursor: pointer;
    transition: background 0.2s ease;
  }
  .send:hover { background: #d2683a; }
  .send:disabled { opacity: 0.6; cursor: default; }

  .foot-hint {
    font-family: var(--body); font-size: 0.88rem; line-height: 1.5;
    color: var(--sage); opacity: 0.8; margin: 0.4rem 0 0;
  }

  .filepick {
    display: flex; align-items: center; gap: 0.8rem; flex-wrap: wrap;
    cursor: pointer;
  }
  .filepick input[type="file"] {
    position: absolute; width: 1px; height: 1px;
    opacity: 0; overflow: hidden;
  }
  .filepick-btn {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.55rem 1rem;
    transition: border-color 0.2s ease;
  }
  .filepick:hover .filepick-btn { border-color: var(--oxide); }
  .filepick input:focus-visible + .filepick-btn { outline: 2px solid var(--oxide); }
  .filepick-hint {
    font-family: var(--mono); font-size: 0.62rem;
    color: var(--sage); opacity: 0.75;
  }

  .filelist { list-style: none; margin: 0.8rem 0 0; padding: 0; }
  .fileitem {
    display: flex; align-items: center; gap: 0.7rem;
    padding: 0.5rem 0.7rem;
    background: var(--basalt-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    margin-bottom: 0.4rem;
  }
  .fileitem-name {
    font-family: var(--body); font-size: 0.92rem;
    color: var(--snowmelt);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .fileitem-size {
    font-family: var(--mono); font-size: 0.6rem;
    color: var(--sage); margin-left: auto; flex: none;
  }
  .fileitem-x {
    font-family: var(--mono); font-size: 0.58rem;
    letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: none; cursor: pointer; flex: none;
  }
  .fileitem-x:hover { color: #d93b1f; }

  .thanks { padding: 2rem 0; }
  .thanks-h {
    font-family: var(--display); font-size: 2rem;
    color: var(--snowmelt); margin: 0 0 0.6rem;
  }
  .thanks-p {
    font-family: var(--body); font-size: 1.1rem; line-height: 1.6;
    color: var(--sage); margin: 0 0 1.6rem;
  }
  .again {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--line); border-radius: 3px;
    padding: 0.6rem 1.1rem; cursor: pointer;
  }
  .again:hover { border-color: var(--oxide); }
</style>
STYLEFIX_EOF

echo "  src/pages/forum.astro"
cat > 'src/pages/forum.astro' << 'STYLEFIX_EOF'
---
import SiteFrame from "../layouts/SiteFrame.astro";
import AuthButton from "../components/AuthButton.astro";
import ThreadComposer from "../components/ThreadComposer.astro";
import "../styles/heat.css";
import "../styles/forum.css";
import { forum } from "../site.config";
---
<SiteFrame title="The Table — Blaine County Preparedness" description="The community forum. Pull up a chair.">
  <div class="table">
    <div class="table-head">
      <div class="table-title-row">
        <span class="heat-dot" data-table-pulse></span>
        <h1 class="h1">The Table</h1>
      </div>
      <div class="table-auth"><AuthButton /></div>
    </div>
    <p class="lede">{forum.line}</p>

    <ThreadComposer mode="picker" />

    <ul class="sections" data-sections>
      <li class="loading">Opening the room…</li>
    </ul>

    <p class="soon" data-empty hidden>
      No threads yet. The chairs are set — someone has to speak first.
    </p>
  </div>
</SiteFrame>

<script>
  import { getSections, heatState } from "../lib/forum";

  const list = document.querySelector("[data-sections]");
  const empty = document.querySelector("[data-empty]");
  const tablePulse = document.querySelector("[data-table-pulse]");

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const sections = await getSections();

  if (!sections.length) {
    list.innerHTML = `<li class="loading">Sections not found.</li>`;
  } else {
    list.innerHTML = sections
      .map((s) => {
        const state = heatState(s.heat);
        const count =
          s.threadCount === 0
            ? "—"
            : `${s.threadCount} thread${s.threadCount === 1 ? "" : "s"}`;
        return `
          <li class="section heat-card" data-heat="${state}">
            <a class="s-link" href="/forum/${esc(s.slug)}">
              <span class="heat-dot"></span>
              <span class="s-text">
                <span class="s-label">${esc(s.label)}</span>
                <span class="s-blurb">${esc(s.blurb ?? "")}</span>
              </span>
              <span class="s-count">${count}</span>
            </a>
            <span class="heat-rail" aria-hidden="true"></span>
          </li>`;
      })
      .join("");

    // The Table's own dot reflects the hottest section.
    const peak = Math.max(...sections.map((s) => s.heat));
    tablePulse.setAttribute("data-heat", heatState(peak));

    const total = sections.reduce((n, s) => n + s.threadCount, 0);
    if (total === 0) empty.hidden = false;
  }
</script>

<style>
  /* An explicit `display` beats the `hidden` attribute, so without
     this, elements meant to be hidden stay on screen. */
  [hidden] { display: none !important; }


  /* Only elements rendered by Astro (not injected by JS) belong here.
     Section/thread card styling lives in src/styles/forum.css —
     scoped styles can't reach runtime-injected markup. */
  .table { max-width: 72ch; margin: 0 auto; }
  .table-head {
    display: flex; flex-direction: column; align-items: center;
    gap: 0.9rem; text-align: center;
  }
  .table-title-row { display: flex; align-items: center; gap: 0.8rem; }
  .h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(2.6rem, 8vw, 4.2rem); line-height: 1.02;
    margin: 0; color: var(--snowmelt);
  }
  .lede {
    font-family: var(--body); font-style: italic; font-size: 1.25rem;
    color: var(--sage); margin: 1rem 0 2.4rem; text-align: center;
  }
  .soon {
    font-family: var(--mono); font-size: 0.72rem; line-height: 1.6;
    color: var(--sage); margin: 0; text-align: center;
  }
  @media (max-width: 560px) {
    .table-auth { width: 100%; display: flex; justify-content: center; }
  }
</style>
STYLEFIX_EOF

echo "  src/pages/forum/thread.astro"
cat > 'src/pages/forum/thread.astro' << 'STYLEFIX_EOF'
---
import SiteFrame from "../../layouts/SiteFrame.astro";
import AuthButton from "../../components/AuthButton.astro";
import "../../styles/heat.css";
import "../../styles/forum.css";
---
<SiteFrame title="Thread — The Table">
  <div class="tp">
    <a class="back" href="/forum" data-back>← The Table</a>

    <article class="post" data-post hidden>
      <h1 class="t-h1" data-post-title></h1>
      <p class="t-by" data-post-meta></p>
      <div class="t-body" data-post-body></div>

      <!-- admin only -->
      <div class="admin" data-admin hidden>
        <label class="admin-label">Move to</label>
        <select class="admin-select" data-move-select></select>
        <button class="admin-btn" type="button" data-move-btn>Move</button>
        <button class="admin-btn danger" type="button" data-hide-btn>Hide thread</button>
      </div>
    </article>

    <p class="loading" data-loading>Opening…</p>

    <ul class="replies" data-replies></ul>

    <!-- reply box -->
    <div class="reply-box" data-replybox hidden>
      <p class="signed-out" data-reply-signedout hidden>Sign in to reply.</p>
      <div class="reply-form" data-reply-form hidden>
        <textarea class="input area" rows="4"
                  placeholder="Add to the conversation."
                  data-reply-body></textarea>
        <p class="notice" data-reply-notice hidden></p>
        <button class="post-btn" type="button" data-reply-post>Reply</button>
      </div>
      <div class="auth-slot"><AuthButton /></div>
    </div>
  </div>
</SiteFrame>

<script>
  import { supabase } from "../../lib/supabase";
  import { getThread, createReply, myProfile, moveThread,
           hideThread, hideReply, approveReply, ago } from "../../lib/forum";

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));

  const id = new URLSearchParams(location.search).get("id");
  const loadingEl = document.querySelector("[data-loading]");
  const postEl    = document.querySelector("[data-post]");
  const repliesEl = document.querySelector("[data-replies]");
  const boxEl     = document.querySelector("[data-replybox]");

  if (!id) {
    loadingEl.textContent = "No thread specified.";
  } else {
    const result = await getThread(id);

    if (!result) {
      loadingEl.textContent = "That thread doesn't exist.";
    } else {
      const { thread, replies } = result;
      const profile = await myProfile();
      const isAdmin = profile?.is_admin === true;

      loadingEl.hidden = true;
      postEl.hidden = false;
      boxEl.hidden = false;

      document.title = `${thread.title} — The Table`;
      document.querySelector("[data-post-title]").textContent = thread.title;
      document.querySelector("[data-post-meta]").textContent =
        `${thread.profiles?.display_name ?? "neighbor"} · ${ago(thread.created_at)}`;
      document.querySelector("[data-post-body]").textContent = thread.body ?? "";

      const back = document.querySelector("[data-back]");
      if (thread.sections?.slug) {
        back.href = `/forum/${thread.sections.slug}`;
        back.textContent = `← ${thread.sections.label}`;
      }

      // ── replies ──
      function renderReplies(list) {
        if (!list.length) {
          repliesEl.innerHTML =
            `<li class="empty">No replies yet. Yours would be the first.</li>`;
          return;
        }
        repliesEl.innerHTML = list.map((r) => `
          <li class="reply${r.is_pending ? " pending" : ""}">
            <div class="r-meta">
              ${esc(r.profiles?.display_name ?? "neighbor")} · ${ago(r.created_at)}
              ${r.is_pending ? '<span class="pending-tag">held for review</span>' : ""}
            </div>
            <div class="r-body">${esc(r.body)}</div>
            ${isAdmin ? `
              <div class="r-admin">
                ${r.is_pending
                  ? `<button class="admin-btn" data-approve="${r.id}">Approve</button>`
                  : ""}
                <button class="admin-btn danger" data-hide-reply="${r.id}">Hide</button>
              </div>` : ""}
          </li>`).join("");

        if (isAdmin) {
          repliesEl.querySelectorAll("[data-approve]").forEach((b) =>
            b.addEventListener("click", async () => {
              await approveReply(b.dataset.approve);
              location.reload();
            }));
          repliesEl.querySelectorAll("[data-hide-reply]").forEach((b) =>
            b.addEventListener("click", async () => {
              await hideReply(b.dataset.hideReply);
              location.reload();
            }));
        }
      }
      renderReplies(replies);

      // ── admin controls on the thread ──
      if (isAdmin) {
        const adminEl = document.querySelector("[data-admin]");
        adminEl.hidden = false;
        const sel = document.querySelector("[data-move-select]");
        const { data: sections } = await supabase
          .from("sections").select("id,label,blurb").order("sort_order");
        sel.innerHTML = (sections ?? [])
          .map((s) => `<option value="${s.id}"${s.id === thread.section_id ? " selected" : ""}>${esc(s.label)}</option>`)
          .join("");

        document.querySelector("[data-move-btn]")
          .addEventListener("click", async () => {
            await moveThread(thread.id, sel.value);
            location.reload();
          });
        document.querySelector("[data-hide-btn]")
          .addEventListener("click", async () => {
            if (!confirm("Hide this thread from the public?")) return;
            await hideThread(thread.id);
            location.href = "/forum";
          });
      }

      // ── reply form ──
      const signedOut = document.querySelector("[data-reply-signedout]");
      const form      = document.querySelector("[data-reply-form]");
      const bodyEl    = document.querySelector("[data-reply-body]");
      const noticeEl  = document.querySelector("[data-reply-notice]");
      const postBtn   = document.querySelector("[data-reply-post]");

      function showForm(session) {
        const inUser = !!session?.user;
        signedOut.hidden = inUser;
        form.hidden = !inUser;
      }
      const { data: sess } = await supabase.auth.getSession();
      showForm(sess.session);
      supabase.auth.onAuthStateChange((_e, s) => showForm(s));

      postBtn.addEventListener("click", async () => {
        postBtn.disabled = true;
        postBtn.textContent = "Posting…";
        noticeEl.hidden = true;

        const res = await createReply(thread.id, bodyEl.value);

        postBtn.disabled = false;
        postBtn.textContent = "Reply";

        if (res.error) {
          noticeEl.textContent = res.error;
          noticeEl.hidden = false;
          return;
        }
        if (res.pending) {
          noticeEl.textContent =
            "Posted — held for review since it's your first. It'll appear once approved.";
          noticeEl.hidden = false;
          bodyEl.value = "";
          return;
        }
        location.reload();
      });
    }
  }
</script>

<style>
  /* An explicit `display` beats the `hidden` attribute, so without
     this, elements meant to be hidden stay on screen. */
  [hidden] { display: none !important; }


  /* Admin controls and reply styling live in src/styles/forum.css
     (unscoped) because they're injected by JavaScript at runtime. */
  .tp { max-width: 68ch; margin: 0 auto; }
  .back {
    font-family: var(--mono); font-size: 0.7rem;
    letter-spacing: 0.12em; text-transform: uppercase; color: var(--sage);
  }
  .back:hover { color: var(--oxide); }

  .post { margin: 1.6rem 0 2.6rem; }
  .t-h1 {
    font-family: var(--display); font-weight: 400;
    font-size: clamp(1.9rem, 5vw, 2.8rem); line-height: 1.08;
    margin: 0 0 0.7rem; color: var(--snowmelt);
  }
</style>
STYLEFIX_EOF

echo "  src/components/ThreadComposer.astro"
cat > 'src/components/ThreadComposer.astro' << 'STYLEFIX_EOF'
---
// ─────────────────────────────────────────────────────────────
//  ThreadComposer — "Start a thread".
//
//  Two modes, set by the `mode` prop:
//    "section"  section comes from context; no picker.
//    "picker"   shows a section chooser with blurbs, so a
//               newcomer can tell Briefs from Preparedness.
//
//  Signed out, it invites sign-in instead of showing the form.
// ─────────────────────────────────────────────────────────────
interface Props {
  mode?: "section" | "picker";
  sectionId?: string;
}
const { mode = "section", sectionId = "" } = Astro.props;
---

<div class="composer" data-composer data-mode={mode} data-section-id={sectionId}>
  <!-- signed out -->
  <p class="signed-out" data-composer-signedout hidden>
    Sign in to start a thread.
  </p>

  <!-- collapsed: the button -->
  <button class="start-btn" type="button" data-composer-open hidden>
    Start a thread
  </button>

  <!-- expanded: the form -->
  <div class="form" data-composer-form hidden>
    {mode === "picker" && (
      <label class="field">
        <span class="label">Which part of The Table?</span>
        <select class="input select" data-composer-section></select>
        <span class="hint" data-composer-hint></span>
      </label>
    )}

    <label class="field">
      <span class="label">Title</span>
      <input class="input" type="text" maxlength="140"
             placeholder="What's this about?" data-composer-title />
    </label>

    <label class="field">
      <span class="label">Say more <span class="opt">(optional)</span></span>
      <textarea class="input area" rows="5"
                placeholder="Context, details, what you need."
                data-composer-body></textarea>
    </label>

    <p class="notice" data-composer-notice hidden></p>

    <div class="actions">
      <button class="post-btn" type="button" data-composer-post>Post it</button>
      <button class="cancel-btn" type="button" data-composer-cancel>Cancel</button>
    </div>
  </div>
</div>

<script>
  import { supabase } from "../lib/supabase";
  import { createThread, currentUser } from "../lib/forum";

  const root = document.querySelector("[data-composer]");
  if (root) {
    const mode      = root.dataset.mode;
    const signedOut = root.querySelector("[data-composer-signedout]");
    const openBtn   = root.querySelector("[data-composer-open]");
    const form      = root.querySelector("[data-composer-form]");
    const titleEl   = root.querySelector("[data-composer-title]");
    const bodyEl    = root.querySelector("[data-composer-body]");
    const noticeEl  = root.querySelector("[data-composer-notice]");
    const postBtn   = root.querySelector("[data-composer-post]");
    const cancelBtn = root.querySelector("[data-composer-cancel]");
    const selectEl  = root.querySelector("[data-composer-section]");
    const hintEl    = root.querySelector("[data-composer-hint]");

    let sections = [];

    function show(session) {
      const inUser = !!session?.user;
      signedOut.hidden = inUser;
      openBtn.hidden = !inUser;
      if (!inUser) form.hidden = true;
    }

    const { data } = await supabase.auth.getSession();
    show(data.session);
    supabase.auth.onAuthStateChange((_e, s) => show(s));

    // Picker mode: load sections with their blurbs so the choice
    // is self-explanatory for someone new.
    if (mode === "picker" && selectEl) {
      const { data: rows } = await supabase
        .from("sections")
        .select("id, label, blurb, sort_order")
        .order("sort_order");
      sections = rows ?? [];
      selectEl.innerHTML = sections
        .map((s) => `<option value="${s.id}">${s.label}</option>`)
        .join("");
      const setHint = () => {
        const s = sections.find((x) => x.id === selectEl.value);
        hintEl.textContent = s?.blurb ?? "";
      };
      selectEl.addEventListener("change", setHint);
      setHint();
    }

    openBtn.addEventListener("click", () => {
      form.hidden = false;
      openBtn.hidden = true;
      titleEl.focus();
    });

    cancelBtn.addEventListener("click", () => {
      form.hidden = true;
      openBtn.hidden = false;
      noticeEl.hidden = true;
      titleEl.value = "";
      bodyEl.value = "";
    });

    postBtn.addEventListener("click", async () => {
      // Read at click time — the section page fills this in
      // after its data loads.
      const sectionId =
        mode === "picker" ? selectEl.value : root.dataset.sectionId;

      if (!sectionId) {
        noticeEl.textContent = "Pick a section first.";
        noticeEl.hidden = false;
        return;
      }

      postBtn.disabled = true;
      postBtn.textContent = "Posting…";
      noticeEl.hidden = true;

      const res = await createThread(sectionId, titleEl.value, bodyEl.value);

      postBtn.disabled = false;
      postBtn.textContent = "Post it";

      if (res.error) {
        noticeEl.textContent = res.error;
        noticeEl.hidden = false;
        return;
      }
      window.location.href = `/forum/thread?id=${res.id}`;
    });
  }
</script>

<style>
  /* An explicit `display` beats the `hidden` attribute, so without
     this, elements meant to be hidden stay on screen. */
  [hidden] { display: none !important; }


  .composer { margin: 0 0 2rem; }

  .signed-out {
    font-family: var(--mono); font-size: 0.72rem;
    color: var(--sage); margin: 0; text-align: center;
  }

  .start-btn {
    display: inline-flex; align-items: center;
    font-family: var(--mono); font-size: 0.74rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--snowmelt); background: transparent;
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.7rem 1.2rem; cursor: pointer;
    transition: background 0.2s ease, border-color 0.2s ease;
  }
  .start-btn:hover { background: rgba(192, 90, 46, 0.1); }

  .form {
    display: flex; flex-direction: column; gap: 1.1rem;
    background: var(--basalt-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    padding: 1.5rem;
  }
  .field { display: flex; flex-direction: column; gap: 0.45rem; }
  .label {
    font-family: var(--mono); font-size: 0.66rem;
    letter-spacing: 0.1em; text-transform: uppercase; color: var(--snowmelt);
  }
  .opt { color: var(--sage); text-transform: none; letter-spacing: 0; }
  .input {
    font-family: var(--body); font-size: 1rem; color: var(--snowmelt);
    background: var(--basalt); border: 1px solid var(--line);
    border-radius: 3px; padding: 0.7rem 0.8rem;
  }
  .input:focus { border-color: var(--oxide); outline: none; }
  .area { resize: vertical; line-height: 1.5; }
  .select { cursor: pointer; }
  .hint {
    font-family: var(--body); font-style: italic;
    font-size: 0.85rem; color: var(--sage);
  }

  .notice {
    font-family: var(--mono); font-size: 0.7rem;
    color: var(--heat-c4, #d93b1f); margin: 0;
  }

  .actions { display: flex; align-items: center; gap: 0.8rem; }
  .post-btn {
    font-family: var(--mono); font-size: 0.72rem;
    letter-spacing: 0.12em; text-transform: uppercase;
    color: var(--basalt); background: var(--oxide);
    border: 1px solid var(--oxide); border-radius: 3px;
    padding: 0.6rem 1.2rem; cursor: pointer;
  }
  .post-btn:hover { background: #d2683a; }
  .post-btn:disabled { opacity: 0.6; cursor: default; }
  .cancel-btn {
    font-family: var(--mono); font-size: 0.66rem;
    letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--sage); background: transparent;
    border: none; cursor: pointer;
  }
  .cancel-btn:hover { color: var(--snowmelt); }
</style>
STYLEFIX_EOF

echo ""
echo "Then: git add -A && git commit -m \"style fixes\" && git push"
