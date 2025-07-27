document.addEventListener('DOMContentLoaded', () => {
  fetch('nonroot-apps.html')
    .then(response => {
      if (!response.ok) throw new Error(); // エラーを投げるが詳細なし
      return response.text();
    })
    .then(html => {
      document.getElementById('nonroot-apps-container').innerHTML = html;

      // 読み込んだ要素にイベントを追加
      const toggleButton = document.getElementById('a1');
      const toggleTarget = document.getElementById('b2');
      if (toggleButton && toggleTarget) {
        toggleButton.addEventListener('click', () => {
          toggleTarget.style.display = (toggleTarget.style.display === 'none') ? 'block' : 'none';
        });
      }
    })
    .catch(() => {
      // エラー時も何も表示しない（完全に無視）
      document.getElementById('nonroot-apps-container').textContent = '';
    });
});
