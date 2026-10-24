// beamai_muse page controllers, loaded after the aihtml runtime (window.AH).

// Enter submits the composer, Shift+Enter adds a newline (aihtml's
// prevent_default filters by key name only, not by modifier).
AH.register("muse-composer", class extends AH.Controller {
  setup() {
    this.listen(this.element, "keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        const form = this.element.closest("form");
        if (form && this.element.value.trim() !== "") form.requestSubmit();
      }
    });
  }
});

// Keep a scroll container pinned to the bottom while new content arrives,
// unless the reader has scrolled up.
AH.register("muse-scroll", class extends AH.Controller {
  setup() {
    const el = this.element;
    let pinned = true;
    this.listen(el, "scroll", () => { pinned = el.scrollHeight - el.scrollTop - el.clientHeight < 40; });
    this.observer = new MutationObserver(() => { if (pinned) el.scrollTop = el.scrollHeight; });
    this.observer.observe(el, { childList: true, subtree: true, characterData: true });
    el.scrollTop = el.scrollHeight;
  }
  teardown() { if (this.observer) this.observer.disconnect(); }
});
