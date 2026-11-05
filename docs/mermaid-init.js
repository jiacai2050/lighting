// Mermaid diagram rendering and reactive dark-mode adaptation for mdBook
(function () {
  let isRendering = false;
  let currentTheme = null;

  function getTheme() {
    const htmlClasses = document.documentElement.classList;
    const isDark =
      htmlClasses.contains("coal") ||
      htmlClasses.contains("navy") ||
      htmlClasses.contains("ayu");
    return isDark ? "dark" : "default";
  }

  async function renderAll(mermaid, forceTheme) {
    if (isRendering) return;
    isRendering = true;

    try {
      const theme = forceTheme || getTheme();
      currentTheme = theme;

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "loose",
        theme: theme,
      });

      // 1. Initial conversion: replace <pre><code class="language-mermaid"> with <div class="mermaid">
      const rawBlocks = document.querySelectorAll("pre code.language-mermaid");
      for (const block of rawBlocks) {
        const pre = block.parentElement;
        if (!pre) continue;
        const div = document.createElement("div");
        div.className = "mermaid";
        div.dataset.mermaidSrc = block.textContent;
        div.textContent = block.textContent;
        pre.replaceWith(div);
      }

      // 2. Re-rendering on theme switch: restore cached source text
      const containers = document.querySelectorAll("div.mermaid");
      for (const container of containers) {
        if (container.dataset.mermaidSrc && container.getAttribute("data-processed")) {
          container.removeAttribute("data-processed");
          container.innerHTML = "";
          container.textContent = container.dataset.mermaidSrc;
        }
      }

      await mermaid.run();
    } catch (err) {
      console.warn("Mermaid failed to render:", err);
    } finally {
      isRendering = false;
    }
  }

  async function initMermaid() {
    const codeBlocks = document.querySelectorAll("pre code.language-mermaid, div.mermaid");
    if (codeBlocks.length === 0) return;

    try {
      const { default: mermaid } = await import(
        "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"
      );

      await renderAll(mermaid);

      // Listen for runtime theme changes (e.g. user clicks mdBook light/dark theme switcher)
      const observer = new MutationObserver(async (mutations) => {
        for (const mutation of mutations) {
          if (mutation.type === "attributes" && mutation.attributeName === "class") {
            const newTheme = getTheme();
            if (newTheme !== currentTheme) {
              await renderAll(mermaid, newTheme);
            }
          }
        }
      });

      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["class"],
      });
    } catch (err) {
      console.warn("Mermaid failed to load:", err);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initMermaid);
  } else {
    initMermaid();
  }
})();
