// Small extras for the DockFolder site. The page works without them.
document.documentElement.classList.add("js");

// Fade sections in as they scroll into view.
const revealed = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    }
  }, { rootMargin: "0px 0px -10% 0px" });
  revealed.forEach((element) => observer.observe(element));
} else {
  revealed.forEach((element) => element.classList.add("is-visible"));
}

// Copy buttons next to Terminal commands.
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 2000);
  });
});

// Show the latest release's version and download size.
fetch("https://api.github.com/repos/breidenbach0/DockFolder/releases/latest")
  .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
  .then((release) => {
    const version = release.tag_name.replace(/^v/, "");
    document.querySelectorAll("[data-version]").forEach((element) => { element.textContent = `Version ${version}`; });
    const dmg = release.assets.find((asset) => asset.name === "DockFolder.dmg");
    if (dmg) {
      const megabytes = (dmg.size / 1_000_000).toFixed(1);
      document.querySelectorAll("[data-size]").forEach((element) => { element.textContent = `${megabytes} MB · version ${version}`; });
    }
  })
  .catch(() => {});
