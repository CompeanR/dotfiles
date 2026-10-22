---
name: social-research
description: Search and read YouTube, Reddit, X and Facebook like a real person, through the user's logged-in Chrome. Use when research should cover these sites, a fetch or search comes back blocked (403, captcha, login wall, "sorry" redirect), or the user shares a youtube.com, reddit.com, x.com or facebook.com link. Facebook is where Mexican gyms, venues and local businesses post.
---

# Social research

WebSearch and WebFetch run from a datacenter IP, so YouTube, Reddit, X and Facebook block them. The user's own Chrome is a residential IP with real sign-ins: search there, the way a person would, and the blocked sources open up.

## Steps

1. **Connect.** Load the `chrome-browser` skill and follow it (tab context first, work in your own new tab). If Claude in Chrome is not connected, tell the user to run `/chrome` and wait. A source you could not open is reported as uncovered, never dropped silently.
2. **Search.** Run the query where a person would:
   - Google: `https://www.google.com/search?q=<query>`, plus `site:reddit.com` and `site:x.com` variants.
   - YouTube: `https://www.youtube.com/results?search_query=<query>`
   - Reddit: `https://www.reddit.com/search/?q=<query>`
   - X: `https://x.com/search?q=<query>&f=live` (latest) or `&f=top`
   - Facebook: `https://www.facebook.com/search/pages/?q=<query>` for businesses (category, address, followers), `/search/groups/` for communities, `/search/posts/` for discussion.
3. **Read the source.** Open each relevant result and read the page text, not the snippet.
   - YouTube: get the transcript with the `youtube-transcript` skill (its `browser.md` route). Note the title, channel and date.
   - Reddit: read the post and the top comment threads. Prefer `old.reddit.com` when the new UI truncates.
   - X: read the full thread and the top replies.
   - Facebook: read the page's About and recent posts; follower counts and "recommend" scores are rough popularity signals, not participation counts.
4. **Cite.** Every claim from these sites names the URL you actually read. Say when a claim comes only from a comment, a creator or a self-reported number.

Done when every source the question needs is read or reported as unreachable, and the tabs you opened are closed.

## Rules

- **Read-only.** You browse as the user: post, like, vote, follow, subscribe and message only on the user's explicit request.
- **Human pace.** Open pages one at a time; a burst of dozens of pages can get the user's accounts rate-limited.
- **One browser driver.** The user's Chrome is a single shared resource. In a Workflow, run browser stages one at a time (a sequential loop, not `parallel()`), or do the browser reading in the main loop and pass the text to agents through `args`.
