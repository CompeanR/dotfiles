# Transcript through the user's Chrome

The fallback for when YouTube blocks the script. It needs Claude in Chrome; load the `chrome-browser` skill first, and if it is not connected, ask the user to run `/chrome`.

## Steps

1. **Open** the watch URL in your own new tab (`navigate` with no tabId creates one).
2. **Load** the transcript: run this with `javascript_tool`. It waits for the page, pauses the video, leaves theater mode, clicks "Show transcript" and polls until the segments render.

   ```js
   const sleep = ms => new Promise(r => setTimeout(r, ms));
   await sleep(2500);
   document.querySelector('video')?.pause();
   const flexy = document.querySelector('ytd-watch-flexy');
   if (flexy?.hasAttribute('theater')) { document.querySelector('.ytp-size-button')?.click(); await sleep(1500); }
   document.querySelector('#description-inline-expander #expand, tp-yt-paper-button#expand')?.click();
   await sleep(800);
   const btn = [...document.querySelectorAll('button')].find(b => /show transcript/i.test(b.innerText || b.getAttribute('aria-label') || ''));
   btn?.click();
   let segs = [];
   for (let i = 0; i < 20 && !segs.length; i++) { await sleep(750); segs = [...document.querySelectorAll('ytd-transcript-segment-renderer, transcript-segment-view-model')]; }
   const lines = [...new Set(segs.map(s => s.innerText.replace(/\s+/g, ' ').trim()))];
   window.__tr = lines;
   JSON.stringify({ button: !!btn, lines: lines.length, chars: lines.join('\n').length, head: lines.slice(0, 3) })
   ```

   Done when `lines` is above zero. If it stays zero, take a screenshot: the video may have no captions, or "Show transcript" may sit under a different label.
3. **Expose** the text as the page body so `get_page_text` can read it in bulk:

   ```js
   const from = 0, to = 450;
   while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
   const pre = document.createElement('pre');
   pre.textContent = window.__tr.slice(from, to).join('\n');
   document.body.appendChild(document.createElement('article')).appendChild(pre);
   `${Math.min(to, window.__tr.length)} of ${window.__tr.length}`
   ```

4. **Read** it with `get_page_text`. It returns up to 50,000 characters, about 450 lines or 40 minutes of talk. For a longer video, rerun step 3 with the next `from`/`to` range and read again until every line is read.
5. **Close** the tab.

## Why this route

Each of these failed on Oct 13, 2026; skip them:

- The caption `baseUrl` from the player response returns an empty body (YouTube now wants a PO token).
- `POST /youtubei/v1/get_transcript` from the page returns 400.
- In theater mode the transcript panel stays `HIDDEN` even after the click.
- `javascript_tool` output is cut at about 1,000 characters and blocks values that contain URL query strings, so return counts from it, never the transcript.
- `innerHTML` throws on YouTube (TrustedHTML), so build nodes with `textContent`.
- The panel renders every segment twice, so the snippet de-duplicates lines.
