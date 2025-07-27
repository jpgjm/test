import { setupSelfResponsibilityToggle } from './script.js';

document.addEventListener('DOMContentLoaded', () => {
  fetch('nonroot-apps.html')
    .then(response => response.text())
    .then(html => {
      document.getElementById('nonroot-apps-container').innerHTML = html;

      // 非同期読み込み後に機能を有効化
      setupSelfResponsibilityToggle();
    });
});
