(() => {
  const root = document.documentElement;
  const body = document.body;
  const languageKey = "xcc-site-language";
  const storedLanguage = window.localStorage.getItem(languageKey);
  const browserLanguage = navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en";
  let currentLanguage = storedLanguage === "en" || storedLanguage === "zh"
    ? storedLanguage
    : browserLanguage;

  const languageToggles = document.querySelectorAll("[data-language-toggle]");
  const scheduleStatus = document.querySelector("[data-schedule-status]");
  const scheduleButtons = document.querySelectorAll("[data-schedule-option]");

  function updateScheduleStatus() {
    if (!scheduleStatus) return;
    const selected = document.querySelector("[data-schedule-option][aria-pressed='true']");
    if (!selected) return;
    scheduleStatus.textContent = currentLanguage === "zh"
      ? selected.dataset.zh
      : selected.dataset.en;
  }

  function applyLanguage(language) {
    currentLanguage = language;
    body.dataset.lang = language;
    root.lang = language === "zh" ? "zh-CN" : "en";
    window.localStorage.setItem(languageKey, language);

    languageToggles.forEach((toggle) => {
      toggle.textContent = language === "zh" ? "EN" : "中文";
      toggle.setAttribute(
        "aria-label",
        language === "zh" ? "Switch site language to English" : "切换为中文"
      );
      toggle.setAttribute("aria-pressed", language === "en" ? "true" : "false");
    });

    updateScheduleStatus();
  }

  languageToggles.forEach((toggle) => {
    toggle.addEventListener("click", () => {
      applyLanguage(currentLanguage === "zh" ? "en" : "zh");
    });
  });

  scheduleButtons.forEach((button) => {
    button.addEventListener("click", () => {
      scheduleButtons.forEach((candidate) => {
        candidate.setAttribute("aria-pressed", candidate === button ? "true" : "false");
      });
      updateScheduleStatus();
    });
  });

  document.querySelectorAll(".mobile-menu-panel a").forEach((link) => {
    link.addEventListener("click", () => {
      const menu = link.closest("details");
      if (menu) menu.removeAttribute("open");
    });
  });

  applyLanguage(currentLanguage);
})();
