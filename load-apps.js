// load-apps.js
document.addEventListener('DOMContentLoaded', () => {
  fetch('nonroot-apps.html')
    .then(response => {
      if (!response.ok) throw new Error('読み込み失敗');
      return response.text();
    })
    .then(html => {
      document.getElementById('nonroot-apps-container').innerHTML = html;
    })
    .catch(error => {
      console.error('エラー:', error);
      document.getElementById('nonroot-apps-container').textContent = 'アプリ一覧の読み込みに失敗しました。';
    });
});
